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

POLL_INTERVAL ::= Duration --m=1

class SynchronizeJobPostgrest extends SynchronizeJob:
  config_/Map := {:}

  constructor logger/log.Logger device/Device applications/ApplicationManager:
    super logger device applications

  commit config/Map actions/List -> Lambda:
    return ::
      actions.do: it.call
      print "updating config from $config_ to $config"
      config_ = config

  fake_update_firmware id/string -> none:
    config_["firmware"] = id

  connect [block]:
    network := net.open
    client := supabase_create_client network
    resources := ResourceManagerPostgrest client SUPABASE_HOST supabase_create_headers

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
