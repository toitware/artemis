// Copyright (C) 2022 Toitware ApS. All rights reserved.

import device
import host.pipe

import .scheduler show Scheduler
import .synchronize show SynchronizeJob

import ..shared.connect show ArtemisDevice

main arguments:
  name := (platform == PLATFORM_FREERTOS)
      ? device.name
      : (pipe.backticks "hostname").trim
  device ::= ArtemisDevice name
  scheduler ::= Scheduler
  scheduler.add_job
      SynchronizeJob device
  scheduler.run
