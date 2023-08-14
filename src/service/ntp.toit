// Copyright (C) 2022 Toitware ApS. All rights reserved.

import esp32
import log
import ntp

import .jobs

class NtpJob extends PeriodicJob:
  logger_/log.Logger

  constructor logger/log.Logger period/Duration:
    logger_ = logger.with-name "ntp"
    super "ntp" period

  run -> none:
    result/ntp.Result? := null
    exception := catch: result = ntp.synchronize
    if exception: logger_.error "failed" --tags={"exception": exception}
    if not result: return
    esp32.adjust-real-time-clock result.adjustment
    logger_.info "synchronized" --tags={
        "adjustment": result.adjustment,
        "time": Time.now.local,
    }
