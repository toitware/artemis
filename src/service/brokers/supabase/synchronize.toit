// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import supabase

import .resources
import ..broker

import ...check_in show check_in
import ...device
import ....shared.server_config

class BrokerServiceSupabase implements BrokerService:
  logger_/log.Logger
  broker_/ServerConfigSupabase

  device_/Device? := null
  client_/supabase.Client? := null

  last_poll_us_/int? := null

  constructor .logger_ .broker_:

  connect --device/Device [block]:
    network := net.open
    check_in network logger_ --device=device

    client := supabase.Client network --server_config=broker_
        --certificate_provider=: throw "UNSUPPORTED"
    resources := ResourceManagerSupabase device client

    try:
      device_ = device
      client_ = client
      block.call resources
    finally:
      device_ = client_ = last_poll_us_ = null
      client.close
      network.close

  fetch_goal --wait/bool -> Map?:
    last := last_poll_us_
    if last:
      elapsed := Duration --us=(Time.monotonic_us - last)
      interval := broker_.poll_interval
      if elapsed < interval:
        if not wait: throw DEADLINE_EXCEEDED_ERROR
        sleep interval - elapsed
    // An empty goal means that we should revert to the
    // firmware state. We must return it.
    result := client_.rest.rpc "toit_artemis.get_goal" {
      "_device_id": device_.id
    }
    last_poll_us_ = Time.monotonic_us
    return result
