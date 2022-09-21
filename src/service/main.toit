// Copyright (C) 2022 Toitware ApS. All rights reserved.

import device
import host.pipe
import log

import .scheduler show Scheduler
import .applications show ApplicationManager

import .synchronize show SynchronizeJob

import ..shared.mqtt.base show DeviceMqtt
import .mqtt.synchronize show SynchronizeJobMqtt

import ..shared.postgrest.supabase show DevicePostgrest
import .postgrest.synchronize show SynchronizeJobPostgrest

import .ntp

USE_SUPABASE ::= false

main arguments:
  logger := log.default.with_name "artemis"
  name := (platform == PLATFORM_FREERTOS)
      ? device.name
      : (pipe.backticks "hostname").trim

  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler

  synchronize/SynchronizeJob? := null
  if USE_SUPABASE:
    device ::= DevicePostgrest name
    synchronize = SynchronizeJobPostgrest logger device applications
  else:
    device ::= DeviceMqtt name
    synchronize = SynchronizeJobMqtt logger device applications

  scheduler.add_jobs [
    synchronize,
    NtpJob logger (Duration --m=1),
  ]
  scheduler.run
