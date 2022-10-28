// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import monitor

import .resources
import ..mediator_service

import ..status show report_status
import ...shared.postgrest.supabase as supabase

POLL_INTERVAL ::= Duration --m=2

class MediatorServicePostgrest implements MediatorService:
  logger_/log.Logger
  broker_/Map
  constructor .logger_ .broker_:

  connect --device_id/string --callback/EventHandler [block]:
    network := net.open
    report_status network logger_
    client := supabase.create_client network broker_
    headers := supabase.create_headers broker_
    resources := ResourceManagerPostgrest client broker_["supabase"]["host"] headers

    disconnected := monitor.Latch
    handle_task/Task? := ?
    handle_task = task::
      try:
        while true:
          info := resources.fetch_json "devices" [ "id=eq.$(device_id)" ]
          new_config/Map? := null
          if info and info.size == 1 and info[0] is Map and info[0].contains "config":
            new_config = info[0]["config"]
          else:
            new_config = {:}
          callback.handle_update_config new_config resources
          sleep POLL_INTERVAL
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
