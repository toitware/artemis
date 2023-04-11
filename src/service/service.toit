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
  provider := ArtemisServiceProvider containers
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
  containers_/ContainerManager

  constructor .containers_:
    super "toit.io/artemis"
        --major=ARTEMIS_VERSION_MAJOR
        --minor=ARTEMIS_VERSION_MINOR
    provides api.ArtemisService.SELECTOR --handler=this --new

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == api.ArtemisService.VERSION_INDEX:
      return version
    if index == api.ArtemisService.CONTAINER_CURRENT_RESTART_INDEX:
      return container_current_restart --gid=gid --wakeup_us=arguments
    if index == api.ArtemisService.CHANNEL_OPEN_INDEX:
      return channel_open client --topic=arguments
    if index == api.ArtemisService.CHANNEL_SEND_INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.send arguments[1]
    if index == api.ArtemisService.CHANNEL_RECEIVE_PAGE_INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.receive_page --peek=arguments[1] --buffer=arguments[2]
    if index == api.ArtemisService.CHANNEL_ACKNOWLEDGE_INDEX:
      channel := (resource client arguments[0]) as ChannelResource
      return channel.acknowledge arguments[1] arguments[2]
    unreachable

  version -> string:
    return ARTEMIS_VERSION

  container_current_restart --gid/int --wakeup_us/int? -> none:
    job := containers_.get --gid=gid
    job.restart --wakeup_us=wakeup_us

  container_current_restart --wakeup_us/int? -> none:
    unreachable  // Here to satisfy the checker.

  channel_open --topic/string -> int?:
    unreachable  // Here to satisfy the checker.

  channel_send handle/int bytes/ByteArray -> none:
    unreachable  // Here to satisfy the checker.

  channel_receive_page handle/int --peek/int --buffer/ByteArray? -> ByteArray:
    unreachable  // Here to satisfy the checker.

  channel_acknowledge handle/int sn/int count/int -> none:
    unreachable  // Here to satisfy the checker.

  channel_open client/int --topic/string -> ChannelResource:
    return ChannelResource this client --topic=topic
