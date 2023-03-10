// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

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
  scheduler.add_jobs jobs

  // Add the application jobs based on the device state.
  state/Map := device.current_state or device.firmware_state
  applications.load state

  // Run the scheduler until it terminates and gives us
  // the wakeup time for the next job to run.
  wakeup := scheduler.run
  duration := JobTime.now.to wakeup
  logger.info "going offline" --tags={"duration": duration}
  return duration
