// Copyright (C) 2023 Toitware ApS. All rights reserved.

import log
import net
import net.wifi
import net.impl

import system.services show ServiceProvider
import system.api.network show NetworkService NetworkServiceClient
import system.base.network show ProxyingNetworkServiceProvider

import .device

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

  constructor logger/log.Logger .device_:
    logger_ = logger.with_name "network"
    super "artemis/network" --major=0 --minor=1
    provides NetworkService.SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY_PREFERRED
        --tags=[TAG_ARTEMIS_NETWORK]

  proxy_mask -> int:
    return proxy_mask_

  open_network -> net.Interface:
    connections := device_.current_state.get "connections"
    network/net.Interface? := null
    if connections and not connections.is_empty:
      // TODO(kasper): For now, we only look at the first entry in
      // the list of connections and we assume it is for WiFi.
      wifi_connection ::= connections.first
      network = wifi.open
          --ssid=wifi_connection["ssid"]
          --password=wifi_connection["password"]
      // TODO(kasper): This isn't very pretty. It feels like the net.impl
      // code needs to be refactored to support this better.
      proxy_mask_ = (network as impl.SystemInterface_).proxy_mask_
    else:
      // It isn't entirely clear if we need this fallback where use
      // the default network provided by the system. For now, it feels
      // like it is worth having here if we end up running on a base
      // firmware image that has some embedded network configuration.
      connection := default_network_service_.connect
      proxy_mask_ = connection[1]
      network = impl.SystemInterface_ default_network_service_ connection
    logger_.info "opened"
    return network

  close_network network/net.Interface -> none:
    proxy_mask_ = null
    network.close
    logger_.info "closed"
