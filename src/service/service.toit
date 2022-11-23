// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .scheduler show Scheduler
import .applications show ApplicationManager

import .synchronize show SynchronizeJob

import .brokers.broker

import .device

import .ntp

import ..shared.broker_config

run_artemis device/Device broker_config/BrokerConfig --start_ntp/bool=true -> none:
  logger := log.default.with_name "artemis"
  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler

  broker := BrokerService logger broker_config

  synchronize/SynchronizeJob := SynchronizeJob logger device applications broker

  jobs := [synchronize]
  if start_ntp:
    jobs.add (NtpJob logger (Duration --m=1))

  scheduler.add_jobs jobs
  scheduler.run
