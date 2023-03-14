// Copyright (C) 2023 Toitware ApS. All rights reserved.

import log
import net
import net.wifi
import net.impl

import system.services show ServiceProvider
import system.api.network show NetworkService NetworkServiceClient
import system.base.network show ProxyingNetworkServiceProvider

import .device

class NetworkManager extends ProxyingNetworkServiceProvider:
  logger_/log.Logger
  device_/Device
  proxy_mask_/int? := null

  constructor logger/log.Logger .device_:
    logger_ = logger.with_name "network"
    logger_.info "starting"
    super "artemis/network" --major=0 --minor=1
    provides NetworkService.SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY_PREFERRED
        --tags=["artemis"]

  proxy_mask -> int:
    return proxy_mask_

  open_network -> net.Interface:
    config := device_.current_state.get "wifi"
    // TODO(kasper): Make this work for the system network too.
    if not config: throw "Network not configured"
    network := wifi.open --ssid=config["ssid"] --password=config["password"]
    // TODO(kasper): This isn't very pretty.
    proxy_mask_ = (network as impl.SystemInterface_).proxy_mask_
    logger_.info "opened"
    return network

  close_network network/net.Interface -> none:
    proxy_mask_ = null
    network.close
    logger_.info "closed"
