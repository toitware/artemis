// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import reader show Reader
import monitor

import .resources
import ..applications
import ..synchronize show SynchronizeJob
import ...shared.device show Device
import ...shared.postgrest.supabase

class SynchronizeJobPostgrest extends SynchronizeJob:
  config_/Map := {:}

  constructor logger/log.Logger device/Device applications/ApplicationManager:
    super logger device applications

  commit config/Map actions/List -> Lambda:
    return ::
      actions.do: it.call
      config_ = config

  // TODO(kasper): Call handle_update_config

  connect [block]:
    network := net.open
    client := create_client network
    resources := ResourceManagerPostgrest client SUPABASE_HOST create_headers

    disconnected := monitor.Latch
    handle_task/Task? := ?
    handle_task = task::
      try:
        while true:
          info := resources.fetch_json "devices" [
            "name=eq.$(device_.name)",
          ]
          if info.size == 1 and info[0] is Map and info[0].contains "config":
            new_config := info[0]["config"]
            handle_update_config resources config_ new_config
          sleep --ms=60_000
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
