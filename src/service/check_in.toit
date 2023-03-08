// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import system.storage

import .artemis_servers.artemis_server
import .utils
import .jobs

import ..shared.server_config


INTERVAL_ ::= Duration --h=24
INTERVAL_BETWEEN_ATTEMPTS_ ::= Duration --m=30

// TODO(kasper): Share the bucket across all of Artemis?
bucket_/storage.Bucket ::= storage.Bucket.open --ram "toit.io/artemis/rtc"
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

check_in network/net.Interface logger/log.Logger:
  now := JobTime.now
  next := check_in_schedule now
  if now < next: return

  last_attempt_ = now
  success := false
  try:
    // TODO(kasper): Let this be more mockable for testing.
    // For now, we just always fail to report when this
    // runs under tests.
    if not check_in_server_: return

    success = check_in_server_.check_in network logger
    if success: logger.info "status reporting succeeded"
    last_success_ = now
  finally:
    if not success: logger.warn "status reporting failed"
    exception := catch: bucket_["check-in"] = {
      "success": last_success_.us,
      "attempt": last_attempt_.us,
    }
    if exception: logger.warn "cannot update status reporting bucket"

/**
Sets up the check-in functionality.

This is the service that contacts the Toitware backend to report that a
  certain device is online and using Artemis.
*/
check_in_setup assets/Map device/Map -> none:
  server_config := decode_server_config "artemis.broker" assets
  if not server_config: return

  hardware_id := device["hardware_id"]
  check_in_server_ = ArtemisServerService server_config --hardware_id=hardware_id
  last := bucket_.get "check-in"
  if not last: return
  catch:
    // If we cannot decode the last success, it is fine
    // that we do not decode the last attempt.
    last_success_ = JobTime last["success"]
    last_attempt_ = JobTime last["attempt"]
