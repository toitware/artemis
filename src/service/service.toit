// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .brokers.broker
import .containers show ContainerManager
import .device
import .ntp
import .jobs
import .scheduler show Scheduler
import .synchronize show SynchronizeJob

import ..shared.server_config

run_artemis device/Device server_config/ServerConfig --start_ntp/bool=true -> Duration:
  logger := log.default.with_name "artemis"
  scheduler ::= Scheduler logger device
  containers ::= ContainerManager logger scheduler
  broker := BrokerService logger server_config

  // Set up the basic jobs.
  synchronize/SynchronizeJob := SynchronizeJob logger device containers broker
  jobs := [synchronize]
  if start_ntp: jobs.add (NtpJob logger (Duration --m=10))
  scheduler.add_jobs jobs

  // Add the container jobs based on the current device state.
  containers.load device.current_state

  // Run the scheduler until it terminates and gives us
  // the wakeup time for the next job to run.
  wakeup := scheduler.run
  duration := JobTime.now.to wakeup
  logger.info "going offline" --tags={"duration": duration}
  return duration
