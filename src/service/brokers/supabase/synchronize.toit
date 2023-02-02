// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import monitor
import supabase

import .resources
import ..broker

import ...check_in show check_in
import ....shared.server_config

IDLE_TIMEOUT  ::= Duration --m=10

class BrokerServiceSupabase implements BrokerService:
  logger_/log.Logger
  broker_/ServerConfigSupabase
  idle_/monitor.Gate ::= monitor.Gate

  constructor .logger_ .broker_:

  connect --device_id/string --callback/EventHandler [block]:
    network := net.open
    check_in network logger_
    idle_.unlock  // We're always idle when we're just connecting.

    client := supabase.Client network --server_config=broker_
        --certificate_provider=: throw "UNSUPPORTED"
    resources := ResourceManagerSupabase client

    disconnected := monitor.Latch
    handle_task/Task? := ?
    handle_task = task --background::
      try:
        while true:
          with_timeout IDLE_TIMEOUT: idle_.enter
          info := client.rest.select "devices" --filters=[ "id=eq.$(device_id)" ]
          new_config/Map? := null
          if info and info.size == 1 and info[0] is Map and info[0].contains "config":
            new_config = info[0]["config"]
          if new_config:
            idle_.lock
            callback.handle_update_config new_config resources
          sleep broker_.poll_interval
      finally:
        critical_do:
          disconnected.set true
          network.close
        handle_task = null
    try:
      block.call resources
    finally:
      if handle_task: handle_task.cancel
      disconnected.get

  on_idle -> none:
    idle_.unlock
