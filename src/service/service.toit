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
import .channels
import .device
import .ntp
import .jobs
import .scheduler show Scheduler
import .synchronize show SynchronizeJob

import ..shared.server_config
import ..shared.version

run_artemis device/Device server_config/ServerConfig -> Duration
    --start_ntp/bool=true
    --cause/string?=null:
  logger := log.default.with_name "artemis"
  tags := {"device": device.id, "version": ARTEMIS_VERSION}
  if cause: tags["cause"] = cause
  logger.info "starting" --tags=tags

  scheduler ::= Scheduler logger device
  containers ::= ContainerManager logger scheduler
  broker := BrokerService logger server_config

  // Set up the basic jobs.
  synchronizer/SynchronizeJob := SynchronizeJob logger device containers broker
  jobs := [synchronizer]
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
  provider := ArtemisServiceProvider containers synchronizer
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

class ArtemisServiceProvider extends ChannelServiceProvider
    implements api.ArtemisService:
  containers_/ContainerManager
  synchronizer_/SynchronizeJob

  constructor .containers_ .synchronizer_:
    super "toit.io/artemis"
        --major=ARTEMIS_VERSION_MAJOR
        --minor=ARTEMIS_VERSION_MINOR
    provides api.ArtemisService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ArtemisService.VERSION_INDEX:
      return version
    if index == api.ArtemisService.CONTAINER_CURRENT_RESTART_INDEX:
      return container_current_restart --gid=gid --wakeup_us=arguments
    if index == api.ArtemisService.CONTROLLER_OPEN_INDEX:
      return controller_open --client=client --mode=arguments
    return super index arguments --gid=gid --client=client

  version -> string:
    return ARTEMIS_VERSION

  container_current_restart --gid/int --wakeup_us/int? -> none:
    job := containers_.get --gid=gid
    job.restart --wakeup_us=wakeup_us

  controller_open --client/int --mode/int -> ControllerResource:
    online := false
    if mode == api.ArtemisService.CONTROLLER_MODE_ONLINE:
      online = true
    else if mode != api.ArtemisService.CONTROLLER_MODE_OFFLINE:
      throw "ILLEGAL_ARGUMENT"
    return ControllerResource this client
        --synchronizer=synchronizer_
        --online=online

  container_current_restart --wakeup_us/int? -> none:
    unreachable  // Here to satisfy the checker.

  controller_open --mode/int -> int:
    unreachable  // Here to satisfy the checker.

class ControllerResource extends services.ServiceResource:
  synchronizer/SynchronizeJob
  online/bool

  constructor provider/ArtemisServiceProvider client/int --.synchronizer --.online:
    super provider client
    synchronizer.control --online=online

  on_closed -> none:
    synchronizer.control --online=online --close
