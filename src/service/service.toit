// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import system.services

// --------------------------------------------------------------------------
// The Artemis package has temporarily been copied from the open
// source repository:
//
// https://github.com/toitware/toit-artemis/blob/main/src/
//
// When the API changes have solidified, the copied directory
// will be deleted in this repository and the new published
// version will be used instead.

// WAS: import artemis.api
import .pkg_artemis_src_copy.api as api

// --------------------------------------------------------------------------

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
  logger.info "starting" --tags={"device": device.id, "version": ARTEMIS_VERSION}

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
  wakeup/JobTime? := null
  provider := ArtemisServiceProvider
  try:
    provider.install
    wakeup = scheduler.run
  finally:
    // We sometimes cancel the scheduler when running tests,
    // so we have to be careful and clean up anyway.
    critical_do: provider.uninstall

  containers.setup_deep_sleep_triggers

  // Compute the duration of the deep sleep and return it.
  duration := JobTime.now.to wakeup
  logger.info "stopping" --tags={"duration": duration}
  return duration

class ArtemisServiceProvider extends services.ServiceProvider
    implements services.ServiceHandlerNew api.ArtemisService:

  constructor:
    super "toit.io/artemis"
        --major=ARTEMIS_VERSION_MAJOR
        --minor=ARTEMIS_VERSION_MINOR
    provides api.ArtemisService.SELECTOR --handler=this --new

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ArtemisService.VERSION_INDEX:
      return version
    if index == api.ArtemisService.CONTAINER_RESTART_INDEX:
      return container_restart --delay_until_us=arguments[0]
    unreachable

  version -> string:
    return ARTEMIS_VERSION

  container_restart --delay_until_us/int? -> none:
    throw "UNIMPLEMENTED"
