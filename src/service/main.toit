// Copyright (C) 2022 Toitware ApS. All rights reserved.

import device
import host.pipe
import log

import .scheduler show Scheduler
import .applications show ApplicationManager

import .mediator_service

import .synchronize show SynchronizeJob

import ..shared.device

import .postgrest.synchronize show MediatorServicePostgrest
import .mqtt.synchronize show MediatorServiceMqtt

import .ntp

USE_SUPABASE ::= false

main arguments:
  logger := log.default.with_name "artemis"
  name := (platform == PLATFORM_FREERTOS)
      ? device.name
      : (pipe.backticks "hostname").trim

  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler

  device := Device name

  mediator/MediatorService := ?
  if USE_SUPABASE:
    mediator = MediatorServicePostgrest
  else:
    mediator = MediatorServiceMqtt logger

  synchronize/SynchronizeJob := SynchronizeJob logger device applications mediator

  scheduler.add_jobs [
    synchronize,
    NtpJob logger (Duration --m=1),
  ]
  scheduler.run
