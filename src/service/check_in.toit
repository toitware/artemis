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

bucket_/storage.Bucket ::= storage.Bucket.open --ram "toit.io/artemis/check-in"
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
  // TODO(kasper): Let this be more mockable for testing.
  // For now, we just always fail to report when this
  // runs under tests.
  if not check_in_server_: return

  now := JobTime.now
  next := check_in_schedule now
  if now < next: return

  last_attempt_ = now
  exception := catch:
    check_in_server_.check_in network logger
    last_success_ = now
  if exception:
    logger.warn "status reporting failed"
        --tags={"exception": exception}
  else:
    logger.info "status reporting succeeded"

  exception = catch:
    bucket_["last"] = {
      "success": last_success_.us,
      "attempt": last_attempt_.us,
    }
  if exception:
    logger.warn "status reporting failed to update bucket"
        --tags={"exception": exception}

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
  last := bucket_.get "last"
  if not last: return
  catch:
    // If we cannot decode the last success, it is fine
    // that we do not decode the last attempt.
    last_success_ = JobTime last["success"]
    last_attempt_ = JobTime last["attempt"]
