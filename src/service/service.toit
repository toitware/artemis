// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import system.containers
import uuid

import .scheduler show Scheduler
import .applications show Application ApplicationManager
import .jobs

import .synchronize show SynchronizeJob

import .brokers.broker

import .device

import .ntp

import ..shared.server_config

run_artemis device/Device server_config/ServerConfig --start_ntp/bool=true -> Duration:
  logger := log.default.with_name "artemis"
  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler
  broker := BrokerService logger server_config

  // Set up the basic jobs.
  synchronize/SynchronizeJob := SynchronizeJob logger device applications broker
  jobs := [synchronize]
  if start_ntp: jobs.add (NtpJob logger (Duration --m=10))

  // Add the application jobs based on the device state.
  state/Map := device.current_state or device.firmware_state
  state.get "apps" --if_present=: | apps |
    installed_ids := Set
    containers.images.do: installed_ids.add it.id
    apps.do: | name description |
      id_string/string? := description.get Application.KEY_ID
      id/uuid.Uuid? := null
      catch: id = id_string and uuid.parse id_string
      if id and installed_ids.contains id:
        logger.info "loaded container image from flash" --tags={"name": name, "id": id_string}
        jobs.add (Application.completed name --id=id --description=description)
      else:
        jobs.add (Application name --id=id_string --description=description)

  scheduler.add_jobs jobs
  wakeup := scheduler.run
  duration := JobTime.now.to wakeup
  logger.info "going offline" --tags={"duration": duration}
  return duration
