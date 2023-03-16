// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import monitor
import supabase

import .resources
import ..broker

import ...check_in show check_in
import ...device
import ....shared.server_config

IDLE_TIMEOUT ::= Duration --m=10

class BrokerServiceSupabase implements BrokerService:
  logger_/log.Logger
  broker_/ServerConfigSupabase
  idle_/monitor.Gate ::= monitor.Gate

  constructor .logger_ .broker_:

  connect --device/Device --callback/EventHandler [block]:
    network := net.open
    check_in network logger_ --device=device

    client := supabase.Client network --server_config=broker_
        --certificate_provider=: throw "UNSUPPORTED"
    resources := ResourceManagerSupabase device client
    disconnected := monitor.Latch

    // Always start non-idle and wait for the $block to call
    // the $on_idle method when it is ready for the handle
    // task to do its work. This avoids processing multiple
    // requests at once.
    idle_.lock

    handle_task/Task? := ?
    handle_task = task --background::
      try:
        while true:
          with_timeout IDLE_TIMEOUT: idle_.enter
          new_goal := client.rest.rpc "toit_artemis.get_goal" {
            "_device_id": device.id
          }
          idle_.lock
          // An empty goal means that we should revert to the
          // firmware state. We must send it to `handle_goal`.
          callback.handle_goal new_goal resources
          sleep broker_.poll_interval
      finally:
        critical_do: disconnected.set true
        handle_task = null

    try:
      block.call resources
    finally:
      if handle_task: handle_task.cancel
      disconnected.get
      client.close
      network.close

  on_idle -> none:
    idle_.unlock
