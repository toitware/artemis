// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .scheduler show Scheduler
import .applications show ApplicationManager

import .synchronize show SynchronizeJob

import .broker
import .brokers.postgrest.synchronize show BrokerServicePostgrest
import .brokers.mqtt.synchronize show BrokerServiceMqtt

import .device

import .ntp

run_artemis device/Device broker_config/Map --firmware/string?=null -> none:
  logger := log.default.with_name "artemis"
  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler

  broker/BrokerService := ?
  if broker_config.contains "supabase":
    broker = BrokerServicePostgrest logger broker_config["supabase"]
  else if broker_config.contains "mqtt":
    broker = BrokerServiceMqtt logger broker_config["mqtt"]
  else:
    throw "unknown broker $broker_config"

  synchronize/SynchronizeJob := SynchronizeJob logger device applications broker
      --firmware=firmware

  scheduler.add_jobs [
    synchronize,
    NtpJob logger (Duration --m=1),
  ]
  scheduler.run
