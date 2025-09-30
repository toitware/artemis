// Copyright (C) 2023 Toitware ApS. All rights reserved.

import log
import net
import net.cellular
import net.ethernet
import net.wifi
import semver

import system
import system.services show ServiceProvider
import system.api.network show NetworkService NetworkServiceClient
import system.base.network show ProxyingNetworkServiceProvider

import .device

// The Artemis network manager is implemented as a network. The
// network it provides is tagged so we can avoid finding it when
// looking for the default network service.
TAG-ARTEMIS-NETWORK ::= "artemis"

DEFAULT-NETWORK-SELECTOR ::=
    NetworkService.SELECTOR.restrict.deny --tag=TAG-ARTEMIS-NETWORK
default-network-service_/NetworkServiceClient? ::=
    (NetworkServiceClient DEFAULT-NETWORK-SELECTOR).open --if-absent=: null

class NetworkManager extends ProxyingNetworkServiceProvider:
  static QUARANTINE-NO-DATA    ::= Duration --m=10
  static QUARANTINE-NO-NETWORK ::= Duration --m=1

  static SYSTEM-NETWORK-NAME ::= "system"

  logger_/log.Logger
  device_/Device
  proxy-mask_/int? := null
  connections_/Map

  constructor logger/log.Logger .device_:
    logger_ = logger.with-name "network"
    connections_ = Connection.map device_ --logger=logger_
    super "artemis/network" --major=0 --minor=1
    provides NetworkService.SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY-PREFERRED-STRONGLY
        --tags=[TAG-ARTEMIS-NETWORK]

  // TODO(kasper): Remove this override once we can tell at the call site
  // of the connect whether we want to avoid opening quarantined networks.
  // Right now, we rely on the collected client id to determine if we're
  // trying to connect from Artemis itself.
  connect-from-client-id_/int? := null
  connect client/int -> List:
    try:
      connect-from-client-id_ = client
      return super client
    finally:
      connect-from-client-id_ = null

  proxy-mask -> int:
    return proxy-mask_

  quarantine name/string -> none:
    connection/Connection? := connections_.get name
    if connection:
      connection.quarantine QUARANTINE-NO-DATA
      logger_.info "quarantined" --tags={"connection": name, "duration": QUARANTINE-NO-DATA}

  open-network -> net.Interface:
    if connections_.is-empty: return open-system-network_
    // Get the connections and sort them according to their quarantining
    // deadline. The sorting is stable so the order in the configuration
    // is used as the tie-breaker.
    connections := connections_.values
    connections.sort --in-place: | a b | a.compare-to b
    // TODO(kasper): For now, we need to determine if we're called from
    // Artemis itself. This isn't super pretty, but it works by testing
    // if the request to connect came through the client stored in the
    // cached net.service_ in the current process. This works as long
    // as the network manager runs as part of the Artemis process.
    client := net.service_
    connect-from-artemis := client and client.id == connect-from-client-id_
    // Try the sorted connections in order.
    connections.do: | connection/Connection |
      if connect-from-artemis and connection.is-quarantined:
        remaining-us := connection.quarantined-until_ - Time.monotonic-us
        remaining-duration := Duration --us=remaining-us
        logger_.debug "quarantined - skipped" --tags={
          "connection": connection.name,
          "duration": remaining-duration,
        }
        continue.do
      network/net.Client? := open-network_ connection
      if network:
        proxy-mask_ = network.proxy-mask
        logger_.info "opened" --tags={"connection": network.name}
        return network
      connection.quarantine QUARANTINE-NO-NETWORK
      logger_.info "quarantined" --tags={"connection": connection.name, "duration": QUARANTINE-NO-NETWORK}
    throw "CONNECT_FAILED: no available networks"

  open-network_ connection/Connection -> net.Client?:
    logger_.info "opening" --tags={"connection": connection.name}
    network/net.Client? := null
    exception := catch: network = connection.open
    if not network:
      logger_.warn "opening failed" --tags={
        "connection": connection.name,
        "error": exception
      }
    return network

  open-system-network_ -> net.Interface:
    // It isn't entirely clear if we need this fallback where use
    // the default network provided by the system. For now, it feels
    // like it is worth having here if we end up running on a base
    // firmware image that has some embedded network configuration.
    logger_.info "opening" --tags={"connection": SYSTEM-NETWORK-NAME}
    network := net.open --name=SYSTEM-NETWORK-NAME --service=default-network-service_
    proxy-mask_ = network.proxy-mask
    logger_.info "opened" --tags={"connection": network.name}
    return network

  close-network network/net.Interface -> none:
    logger_.info "closing" --tags={"connection": network.name}
    proxy-mask_ = null
    network.close
    logger_.info "closed" --tags={"connection": network.name}

abstract class Connection implements Comparable:
  description_/Map
  index/int
  quarantined-until_/int? := null
  constructor .index .description_:

  abstract name -> string
  abstract open -> net.Client

  is-quarantined -> bool:
    end := quarantined-until_
    if not end: return false
    if Time.monotonic-us < end: return true
    quarantined-until_ = null
    return false

  quarantine duration/Duration -> none:
    current := quarantined-until_
    proposed := Time.monotonic-us + duration.in-us
    quarantined-until_ = current ? (max current proposed) : proposed

  compare-to other/Connection -> int:
    return (quarantined-until_ or 0).compare-to (other.quarantined-until_ or 0)

  compare-to other/Connection [--if-equal] -> int:
    result := compare-to other
    return result == 0 ? if-equal.call : result

  static map device/Device --logger/log.Logger -> Map:
    result := {:}
    connections := device.current-state.get "connections" --if-absent=: []
    connections.size.repeat: | index/int |
      description/Map := connections[index]
      connection/Connection? := null
      type := description.get "type"
      if type == "wifi":
        connection = ConnectionWifi index description
      else if type == "cellular":
        connection = ConnectionCellular index description
      else if type == "ethernet":
        connection = ConnectionEthernet index description
      else if type:
        logger.warn "connection has unknown type" --tags={"connection": description}
      else:
        logger.error "connection has missing type" --tags={"connection": description}
      if connection: result[connection.name] = connection
    return result

class ConnectionWifi extends Connection:
  constructor index/int description/Map:
    super index description

  name -> string:
    return "wifi-$index"

  open -> net.Client:
    ssid/string? := description_["ssid"]
    // If the ssid is not provided, we use the configurable
    // setting stored on the device, so the WiFi credentials
    // can be set through some kind of provisioning step.
    if not ssid: return wifi.open --name=name null
    return wifi.open
        --name=name
        --ssid=ssid
        --password=description_["password"]

class ConnectionCellular extends Connection:
  constructor index/int description/Map:
    super index description

  name -> string:
    return "cellular-$index"

  open -> net.Client:
    // Artemis is long running, so we let the network
    // manager clean up and re-resolve the services
    // if things have changed since last attempt.
    cellular.reset
    config := description_.get "config" --if-absent=: {:}
    if config.contains-key "log.level":
      config-level := config["log.level"]
      level := config-level
      if level is string:
        // Replace with int value.
        LOG_LEVELS ::= ["TRACE", "DEBUG", "INFO", "WARNING", "ERROR", "FATAL"]
        level = LOG_LEVELS.index-of level
        if level < 0: throw "INVALID_CELLULAR_LOG_LEVEL"
        // Decrement to handle the log-level change below.
        level--
      // Log levels have changed with SDK alpha.189. Adjust accordingly.
      needs-adjustment := (semver.compare system.vm-sdk-version "2.0.0-alpha.189") >= 0
      if needs-adjustment:
        level++
      else if level < 0:
        // There was no trace level before 2.0.0-alpha.189.
        level = 0
      if level != config-level:
        config = config.copy
        config["log.level"] = level
    return cellular.open --name=name config

class ConnectionEthernet extends Connection:
  constructor index/int description/Map:
    super index description

  name -> string:
    return "ethernet-$index"

  open -> net.Client:
    // Artemis is long running, so we let the network
    // manager clean up and re-resolve the services
    // if things have changed since last attempt.
    ethernet.reset
    return ethernet.open --name=name
