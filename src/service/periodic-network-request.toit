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

  constructor .name .device --.period --.backoff:
    last := device.periodic-network-request-last
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
      logger.warn "request failed"
          --tags={"exception": exception}
    else:
      logger.info "request succeeded"

    exception = catch:
      device.periodic-network-request-last-update {
        "+$name": last-success_ and last-success_.us,
        "?$name": last-attempt_.us,
      }
    if exception:
      logger.warn "request failed to update local state"
          --tags={"exception": exception}
