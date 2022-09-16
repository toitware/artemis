// Copyright (C) 2022 Toitware ApS. All rights reserved.

import device
import host.pipe
import log

import .scheduler show Scheduler
import .applications show ApplicationManager
import .mqtt.synchronize show SynchronizeJobMqtt

import .ntp
import ..shared.connect show DeviceMqtt

main arguments:
  logger := log.default.with_name "artemis"
  name := (platform == PLATFORM_FREERTOS)
      ? device.name
      : (pipe.backticks "hostname").trim
  device ::= DeviceMqtt name

  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler
  scheduler.add_jobs [
      SynchronizeJobMqtt logger device applications,
      NtpJob logger (Duration --m=1),
  ]
  scheduler.run
