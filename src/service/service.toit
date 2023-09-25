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
import .pkg-artemis-src-copy.api as api

// --------------------------------------------------------------------------

import .brokers.broker
import .containers show ContainerManager ContainerJob
import .channels
import .device
import .ntp
import .jobs
import .scheduler show Scheduler
import .synchronize show SynchronizeJob

import ..shared.server-config
import ..shared.version

run-artemis device/Device server-config/ServerConfig -> Duration
    --start-ntp/bool=true
    --cause/string?=null:
  logger := log.default.with-name "artemis"
  tags := {"device": device.id, "version": ARTEMIS-VERSION}
  if cause: tags["cause"] = cause
  logger.info "starting" --tags=tags

  scheduler ::= Scheduler logger device
  containers ::= ContainerManager logger scheduler
  broker := BrokerService logger server-config

  job-states := device.scheduler-jobs-state
  // Set up the basic jobs.
  synchronize-state := job-states.get SynchronizeJob.NAME
  synchronizer/SynchronizeJob := SynchronizeJob logger device containers broker synchronize-state
  jobs := [synchronizer]
  if start-ntp:
    ntp-state := job-states.get NtpJob.NAME
    jobs.add (NtpJob logger ntp-state (Duration --m=10))
  scheduler.add-jobs jobs

  // Add the container jobs based on the current device state.
  containers.load device.current-state job-states

  // Run the scheduler until it terminates and gives us
  // the wakeup time for the next job to run. While we
  // run the scheduler, we provide an implementation of
  // the Artemis API so user code can interact with us
  // at runtime and not just through the broker.
  wakeup/JobTime? := null
  provider := ArtemisServiceProvider device containers synchronizer
  try:
    provider.install
    wakeup = scheduler.run
  finally:
    // We sometimes cancel the scheduler when running tests,
    // so we have to be careful and clean up anyway.
    critical-do: provider.uninstall

    // For now, we only update the storage bucket when we're
    // shutting down. This means that if hit an exceptional
    // case, we will reschedule all jobs.
    job-states = {:}
    scheduler.jobs_.do: | job/Job |
      if deep-sleep-state := job.deep-sleep-state:
        job-states[job.name] = deep-sleep-state
    device.scheduler-jobs-state-update job-states

  containers.setup-deep-sleep-triggers

  // Compute the duration of the deep sleep and return it.
  duration := JobTime.now.to wakeup
  logger.info "stopping" --tags={"duration": duration}
  return duration

class ArtemisServiceProvider extends ChannelServiceProvider
    implements api.ArtemisService:
  device_/Device
  containers_/ContainerManager
  synchronizer_/SynchronizeJob

  constructor .device_ .containers_ .synchronizer_:
    super "toit.io/artemis"
        --major=ARTEMIS-VERSION-MAJOR
        --minor=ARTEMIS-VERSION-MINOR
    provides api.ArtemisService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ArtemisService.VERSION-INDEX:
      return version
    if index == api.ArtemisService.CONTAINER-CURRENT-RESTART-INDEX:
      return container-current-restart --gid=gid --wakeup-us=arguments
    if index == api.ArtemisService.CONTAINER-CURRENT-TRIGGER-INDEX:
      return container-current-trigger --gid=gid
    if index == api.ArtemisService.CONTAINER-CURRENT-TRIGGERS-INDEX:
      return container-current-triggers --gid=gid
    if index == api.ArtemisService.CONTROLLER-OPEN-INDEX:
      return controller-open --client=client --mode=arguments
    if index == api.ArtemisService.DEVICE-ID-INDEX:
      return device-id
    return super index arguments --gid=gid --client=client

  version -> string:
    return ARTEMIS-VERSION

  device-id -> ByteArray:
    return device_.id.to-byte-array

  container-current-restart --gid/int --wakeup-us/int? -> none:
    job := containers_.get --gid=gid
    job.restart --wakeup-us=wakeup-us

  container-current-trigger --gid/int -> int:
    job := containers_.get --gid=gid
    if job is not ContainerJob:
      return -1
    return (job as ContainerJob).last-trigger-reason_

  container-current-triggers --gid/int -> List?:
    job := containers_.get --gid=gid
    if job is not ContainerJob:
      return null
    container_job := job as ContainerJob
    return (job as ContainerJob).all-active-triggers

  controller-open --client/int --mode/int -> ControllerResource:
    online := false
    if mode == api.ArtemisService.CONTROLLER-MODE-ONLINE:
      online = true
    else if mode != api.ArtemisService.CONTROLLER-MODE-OFFLINE:
      throw "ILLEGAL_ARGUMENT"
    return ControllerResource this client
        --synchronizer=synchronizer_
        --online=online

  container-current-restart --wakeup-us/int? -> none:
    unreachable  // Here to satisfy the checker.

  container-current-trigger -> int:
    unreachable  // Here to satisfy the checker.

  container-current-triggers -> List:
    unreachable  // Here to satisfy the checker.

  controller-open --mode/int -> int:
    unreachable  // Here to satisfy the checker.

class ControllerResource extends services.ServiceResource:
  synchronizer/SynchronizeJob
  online/bool

  constructor provider/ArtemisServiceProvider client/int --.synchronizer --.online:
    super provider client
    synchronizer.control --online=online

  on-closed -> none:
    synchronizer.control --online=online --close
