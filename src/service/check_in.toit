// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net

import .artemis-servers.artemis-server
import .device
import .jobs
import .utils

import ..shared.server-config

INTERVAL_ ::= Duration --h=24
INTERVAL-BETWEEN-ATTEMPTS_ ::= Duration --m=30

last-success_/JobTime? := null
last-attempt_/JobTime? := null

check-in-server_/ArtemisServerService? := null

check-in-schedule now/JobTime -> JobTime:
  if not last-attempt_: return now
  next := last-attempt_ + INTERVAL-BETWEEN-ATTEMPTS_
  if last-success_: next = max next (last-success_ + INTERVAL_)
  return next

check-in network/net.Interface logger/log.Logger --device/Device:
  now := JobTime.now
  next := check-in-schedule now
  if now < next: return

  // TODO(kasper): Let this be more mockable for testing.
  // For now, we just always fail to report when this
  // runs under tests. We need to keep the last attempt
  // time stamp updated to avoid continuously attempting
  // to check in.
  last-attempt_ = now
  if not check-in-server_: return

  exception := catch:
    check-in-server_.check-in network logger
    last-success_ = now
  if exception:
    logger.warn "check-in failed"
        --tags={"exception": exception}
  else:
    logger.info "check-in succeeded"

  exception = catch:
    device.check-in-last-update {
      "success": last-success_ and last-success_.us,
      "attempt": last-attempt_.us,
    }
  if exception:
    logger.warn "check-in failed to update local state"
        --tags={"exception": exception}

/**
Sets up the check-in functionality.

This is the service that contacts the Toitware backend to report that a
  certain device is online and using Artemis.
*/
check-in-setup --assets/Map --device/Device -> none:
  server-config := decode-server-config "artemis.broker" assets
  if not server-config: return

  check-in-server_ = ArtemisServerService server-config
      --hardware-id=device.hardware-id
  last := device.check-in-last
  catch:
    // If we cannot decode the last success, it is fine
    // that we do not decode the last attempt.
    success := last.get "success"
    last-success_ = success and JobTime success
    last-attempt_ = JobTime last["attempt"]
