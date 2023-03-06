// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .scheduler show Scheduler
import .applications show ApplicationManager
import .jobs

import .synchronize show SynchronizeJob

import .brokers.broker

import .device

import .ntp

import ..shared.server_config

run_artemis device/Device server_config/ServerConfig --start_ntp/bool=true -> none:
  logger := log.default.with_name "artemis"
  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler

  broker := BrokerService logger server_config

  synchronize/SynchronizeJob := SynchronizeJob logger device applications broker

  jobs := [synchronize]
  if start_ntp: jobs.add (NtpJob logger (Duration --m=10))

  scheduler.add_jobs jobs
  while true:
    wakeup := scheduler.run
    duration := JobTime.now.to wakeup
    logger.info "going to (simulated deep) sleep" --tags={"duration": duration.stringify}
    sleep duration
    2.repeat: print
