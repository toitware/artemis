// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .scheduler show Scheduler
import .applications show ApplicationManager

import .synchronize show SynchronizeJob

import .mediator_service
import .postgrest.synchronize show MediatorServicePostgrest
import .mqtt.synchronize show MediatorServiceMqtt

import ..shared.device

import .ntp

run_artemis device/Device broker/Map --firmware/string?=null -> none:
  logger := log.default.with_name "artemis"
  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler

  mediator/MediatorService := ?
  if broker.contains "supabase":
    mediator = MediatorServicePostgrest logger broker["supabase"]
  else if broker.contains "mqtt":
    mediator = MediatorServiceMqtt logger broker["mqtt"]
  else:
    throw "unknown broker $broker"

  synchronize/SynchronizeJob := SynchronizeJob logger device applications mediator
      --firmware=firmware

  scheduler.add_jobs [
    synchronize,
    NtpJob logger (Duration --m=1),
  ]
  scheduler.run
