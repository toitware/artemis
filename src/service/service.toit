// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .scheduler show Scheduler
import .applications show ApplicationManager

import .synchronize show SynchronizeJob

import .broker
import .brokers.postgrest.synchronize show BrokerServicePostgrest
import .brokers.mqtt.synchronize show BrokerServiceMqtt
import .brokers.http.synchronize show BrokerServiceHttp

import .device

import .ntp

import ..shared.broker_config

run_artemis device/Device broker_config/BrokerConfig --start_ntp/bool=true -> none:
  logger := log.default.with_name "artemis"
  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler

  broker/BrokerService := ?
  if broker_config is BrokerConfigSupabase:
    broker = BrokerServicePostgrest logger (broker_config as BrokerConfigSupabase)
  else if broker_config is BrokerConfigMqtt:
    broker = BrokerServiceMqtt logger --broker_config=(broker_config as BrokerConfigMqtt)
  else if broker_config is BrokerConfigToitHttp:
    http_broker_config := broker_config as BrokerConfigToitHttp
    broker = BrokerServiceHttp logger http_broker_config.host http_broker_config.port
  else:
    throw "unknown broker $broker_config"

  synchronize/SynchronizeJob := SynchronizeJob logger device applications broker

  jobs := [synchronize]
  if start_ntp:
    jobs.add (NtpJob logger (Duration --m=1))

  scheduler.add_jobs jobs
  scheduler.run
