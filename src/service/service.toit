// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import system.services
import artemis.api.artemis as api  // TODO(kasper): Will change this to just api.

import .brokers.broker
import .containers show ContainerManager
import .device
import .ntp
import .jobs
import .scheduler show Scheduler
import .synchronize show SynchronizeJob

import ..shared.server_config
import ..shared.version

run_artemis device/Device server_config/ServerConfig --start_ntp/bool=true -> Duration:
  logger := log.default.with_name "artemis"
  logger.info "starting" --tags={"device": device.id}

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
  // the wakeup time for the next job to run. While we
  // run the scheduler, we provide an implementation of
  // the Artemis API so user code can interact with us
  // at runtime and not just through the broker.
  provider := ArtemisServiceProvider
  provider.install
  wakeup := scheduler.run
  provider.uninstall

  // Compute the duration of the deep sleep and return it.
  duration := JobTime.now.to wakeup
  logger.info "stopping" --tags={"duration": duration}
  return duration

class ArtemisServiceProvider extends services.ServiceProvider
    implements services.ServiceHandler api.ArtemisService:

  constructor:
    super "toit.io/artemis"
        --major=ARTEMIS_VERSION_MAJOR
        --minor=ARTEMIS_VERSION_MINOR
    provides api.ArtemisService.SELECTOR --handler=this

  handle pid/int client/int index/int arguments/any -> any:
    if index == api.ArtemisService.VERSION_INDEX:
      return version
    unreachable

  version -> string:
    return ARTEMIS_VERSION
