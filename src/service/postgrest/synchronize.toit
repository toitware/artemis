// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import reader show Reader
import monitor

import .resources
import ..mediator_service
import ..applications
import ..synchronize show SynchronizeJob
import ...shared.device show Device
import ...shared.postgrest.supabase

POLL_INTERVAL ::= Duration --m=1

class MediatorServicePostgrest implements MediatorService:
  connect --device_id/string --callback/MediatorServiceCallback [block]:
    network := net.open
    client := supabase_create_client network
    resources := ResourceManagerPostgrest client SUPABASE_HOST supabase_create_headers

    disconnected := monitor.Latch
    handle_task/Task? := ?
    handle_task = task::
      try:
        while true:
          info := resources.fetch_json "devices" [
            "name=eq.$(device_id)",
          ]
          if info.size == 1 and info[0] is Map and info[0].contains "config":
            new_config := info[0]["config"]
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
