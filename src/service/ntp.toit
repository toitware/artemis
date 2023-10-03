// Copyright (C) 2022 Toitware ApS. All rights reserved.

import esp32
import log
import net
import ntp

import .device
import .jobs
import .periodic-network-request

class NtpRequest extends PeriodicNetworkRequest:
  constructor period/Duration --device/Device:
    super "ntp" device
        --period=period
        --backoff=period

  request network/net.Interface logger/log.Logger -> none:
    result/ntp.Result? := ntp.synchronize --network=network
    if not result: return
    esp32.adjust-real-time-clock result.adjustment
    logger.info "synchronized" --tags={
      "adjustment": result.adjustment,
      "time": Time.now.local,
    }
