// Copyright (C) 2022 Toitware ApS. All rights reserved.

import esp32
import log
import ntp

import .jobs

class NtpJob extends PeriodicJob:
  logger_/log.Logger

  constructor logger/log.Logger period/Duration:
    logger_ = logger.with_name "ntp"
    super "ntp" period

  run -> none:
    result ::= ntp.synchronize
    if not result: return
    esp32.adjust_real_time_clock result.adjustment
    logger_.info "synchronized" --tags={
        "adjustment": result.adjustment,
        "time": Time.now.local,
    }
