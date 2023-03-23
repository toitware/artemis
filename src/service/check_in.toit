// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net

import .artemis_servers.artemis_server
import .device
import .jobs
import .utils

import ..shared.server_config

INTERVAL_ ::= Duration --h=24
INTERVAL_BETWEEN_ATTEMPTS_ ::= Duration --m=30

last_success_/JobTime? := null
last_attempt_/JobTime? := null

check_in_server_/ArtemisServerService? := null

check_in_schedule now/JobTime -> JobTime:
  if not last_attempt_: return now
  next := last_attempt_ + INTERVAL_BETWEEN_ATTEMPTS_
  if last_success_: next = max next (last_success_ + INTERVAL_)
  return next

check_in_timeout -> Duration?:
  now := JobTime.now
  next := check_in_schedule now
  return now.to next

check_in network/net.Interface logger/log.Logger --device/Device:
  now := JobTime.now
  next := check_in_schedule now
  if now < next: return

  // TODO(kasper): Let this be more mockable for testing.
  // For now, we just always fail to report when this
  // runs under tests. We need to keep the last attempt
  // time stamp updated to avoid continuously attempting
  // to check in.
  last_attempt_ = now
  if not check_in_server_: return

  exception := catch:
    check_in_server_.check_in network logger
    last_success_ = now
  if exception:
    logger.warn "check-in failed"
        --tags={"exception": exception}
  else:
    logger.info "check-in succeeded"

  exception = catch:
    device.check_in_last_update {
      "success": last_success_ and last_success_.us,
      "attempt": last_attempt_.us,
    }
  if exception:
    logger.warn "check-in failed to update local state"
        --tags={"exception": exception}

/**
Sets up the check-in functionality.

This is the service that contacts the Toitware backend to report that a
  certain device is online and using Artemis.
*/
check_in_setup --assets/Map --device/Device -> none:
  server_config := decode_server_config "artemis.broker" assets
  if not server_config: return

  check_in_server_ = ArtemisServerService server_config
      --hardware_id=device.hardware_id
  last := device.check_in_last
  catch:
    // If we cannot decode the last success, it is fine
    // that we do not decode the last attempt.
    success := last.get "success"
    last_success_ = success and JobTime success
    last_attempt_ = JobTime last["attempt"]
