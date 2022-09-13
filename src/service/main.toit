// Copyright (C) 2022 Toitware ApS. All rights reserved.

import device
import host.pipe
import log

import .scheduler show Scheduler
import .applications show ApplicationManager
import .synchronize show SynchronizeJob

import .ntp
import ..shared.connect show ArtemisDevice

main arguments:
  logger := log.default.with_name "artemis"
  name := (platform == PLATFORM_FREERTOS)
      ? device.name
      : (pipe.backticks "hostname").trim
  device ::= ArtemisDevice name

  scheduler ::= Scheduler logger
  applications ::= ApplicationManager logger scheduler
  scheduler.add_jobs [
      SynchronizeJob logger device applications,
      NtpJob logger (Duration --m=1),
  ]
  scheduler.run
