// Copyright (C) 2023 Toitware ApS. All rights reserved.

import log
import net
import net.wifi
import net.cellular

import system.services show ServiceProvider
import system.api.network show NetworkService NetworkServiceClient
import system.base.network show ProxyingNetworkServiceProvider

import .device
import .jobs show time_now_us

// The Artemis network manager is implemented as a network. The
// network it provides is tagged so we can avoid finding it when
// looking for the default network service.
TAG_ARTEMIS_NETWORK ::= "artemis"

DEFAULT_NETWORK_SELECTOR ::=
    NetworkService.SELECTOR.restrict.deny --tag=TAG_ARTEMIS_NETWORK
default_network_service_/NetworkServiceClient? ::=
    (NetworkServiceClient DEFAULT_NETWORK_SELECTOR).open --if_absent=: null

class NetworkManager extends ProxyingNetworkServiceProvider:
  logger_/log.Logger
  device_/Device
  proxy_mask_/int? := null

  connections_/Map
  quarantines_/List

  constructor logger/log.Logger .device_:
    logger_ = logger.with_name "network"
    connections_ = Connection.map device_ --logger=logger_
    quarantines := device_.connection_quarantines
    quarantines_ = quarantines ? quarantines.copy : (List connections_.size)
    super "artemis/network" --major=0 --minor=1
    provides NetworkService.SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY_PREFERRED
        --tags=[TAG_ARTEMIS_NETWORK]

  proxy_mask -> int:
    return proxy_mask_

  quarantine name/string -> none:
    connection := connections_.get name
    if connection: connection.quarantine (Duration --m=5)

  open_network -> net.Interface:
    if connections_.is_empty: return open_system_network_
    // TODO(kasper): This seems subtle. It feels like we will
    // try some networks more than once, which isn't what
    // I really wanted.
    connections_.size.repeat:
      connection := choose_connection_
      network/net.Client? := open_network_ connection
      if not network:
        quarantine_ connection (Duration --m=2)
        continue.repeat
      proxy_mask_ = network.proxy_mask
      logger_.info "opened" --tags={"connection": network.name}
      return network
    throw "CONNECT_FAILED: no available networks"

  open_network_ connection/Connection -> net.Client?:
    network/net.Client? := null
    exception := catch: network = connection.open
    if not network:
      logger_.warn "connect failed" --tags={
        "connection": connection.name,
        "error": exception
      }
    return network

  open_system_network_ -> net.Interface:
    // It isn't entirely clear if we need this fallback where use
    // the default network provided by the system. For now, it feels
    // like it is worth having here if we end up running on a base
    // firmware image that has some embedded network configuration.
    network := net.open --name="default" --service=default_network_service_
    proxy_mask_ = network.proxy_mask
    logger_.info "opened" --tags={"connection": network.name}
    return network

  close_network network/net.Interface -> none:
    proxy_mask_ = null
    network.close
    logger_.info "closed" --tags={"connection": network.name}

  choose_connection_ -> Connection:
    assert: not connections_.is_empty
    best/Connection? := null
    connections_.do --values: | connection/Connection |
      quarantine := quarantines_[connection.index]
      if not quarantine: return connection
      if not best or quarantine < quarantines_[best.index]: best = connection
    return best

  quarantine_ connection/Connection duration/Duration -> none:
    index := connection.index
    current/int? := quarantines_[index]
    proposed := time_now_us + duration.in_us
    value := current ? (max current proposed) : proposed
    if value == current: return
    quarantines_[index] = value
    device_.connection_quarantines_update quarantines_

abstract class Connection:
  description_/Map
  index/int
  constructor .index .description_:

  abstract name -> string
  abstract open -> net.Client

  static map device/Device --logger/log.Logger -> Map:
    quarantines := device.connection_quarantines
    quarantines = quarantines ? quarantines.copy : []

    result := {:}
    connections := device.current_state.get "connections" --if_absent=: []
    connections.size.repeat: | index/int |
      description/Map := connections[index]
      type := description.get "type"
      if not type:
        logger.error "connection has no type" --tags={"connection": description}
        continue.repeat
      connection/Connection? := ?
      if type == "wifi":
        connection = ConnectionWifi index description
      else if type == "cellular":
        connection = ConnectionCellular index description
      else:
        logger.warn "connection has unknown type" --tags={"connection": description}
        continue.repeat
      result[connection.name] = connection
    return result

class ConnectionWifi extends Connection:
  constructor index/int description/Map:
    super index description

  name -> string:
    return "wifi-$index"

  open -> net.Client:
    return wifi.open
        --name=name
        --ssid=description_["ssid"]
        --password=description_["password"]

class ConnectionCellular extends Connection:
  constructor index/int description/Map:
    super index description

  name -> string:
    return "cellular-$index"

  open -> net.Client:
    return cellular.open --name=name description_["config"]
