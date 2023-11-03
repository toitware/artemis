// Copyright (C) 2023 Toitware ApS. All rights reserved.

import net
import log

import .device show Device
import .jobs show JobTime
import .synchronize show SynchronizeJob  // For toitdoc.

/**
Periodic network requests allow Artemis to periodically interact
  with network resources. They are typically used to drive activity
  that does not have to happen on a fixed schedule, but just with
  reasonably regular intervals.

Periodic network requests are always run from within the
  $SynchronizeJob, so they can piggyback on an already established
  network connection and respect when Artemis is forced offline.
*/
abstract class PeriodicNetworkRequest:
  name/string
  device/Device
  period/Duration
  backoff/Duration

  last-success_/JobTime? := null
  last-attempt_/JobTime? := null

  // Keep a cache of the map of the last successes and attempts
  // around, so we can update it in place before writing it back.
  static last-cache_/Map? := null

  constructor .name .device --.period --.backoff:
    last := last-cache_
    if not last:
      stored := device.periodic-network-request-last
      // We need the last map to be modifiable, so we copy
      // it if we got it from the storage bucket.
      last = stored is Map ? stored.copy : {:}
      last-cache_ = last
    catch:
      // If we cannot decode the last success, it is fine
      // that we do not decode the last attempt.
      success := last.get "+$name"
      last-success_ = success and JobTime success
      last-attempt_ = JobTime last["?$name"]

  abstract request network/net.Interface logger/log.Logger -> none

  schedule now/JobTime -> JobTime:
    if not last-attempt_: return now
    next := last-attempt_ + backoff
    if last-success_: next = max next (last-success_ + period)
    return next

  schedule-now -> bool:
    now := JobTime.now
    return (schedule now) <= now

  run network/net.Interface logger/log.Logger -> none:
    now := JobTime.now
    next := schedule now
    if now < next: return

    // TODO(kasper): Consider constructing this logger
    // once and for all and drop the logger parameter
    // to run?
    logger = logger.with-name name

    last-attempt_ = now
    exception := catch:
      request network logger
      last-success_ = now

    if exception:
      logger.warn "failed" --tags={"exception": exception}

    exception = catch:
      last := last-cache_
      last["+$name"] = last-success_ and last-success_.us
      last["?$name"] = last-attempt_.us
      device.periodic-network-request-last-update last
      last-cache_ = last
    if exception:
      logger.warn "failed to update local state" --tags={
        "exception": exception
      }
