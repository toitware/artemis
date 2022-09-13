// Copyright (C) 2022 Toitware ApS. All rights reserved.

import device
import host.pipe

import .scheduler show Scheduler
import .applications show ApplicationManager
import .synchronize show SynchronizeJob

import ..shared.connect show ArtemisDevice

main arguments:
  name := (platform == PLATFORM_FREERTOS)
      ? device.name
      : (pipe.backticks "hostname").trim
  device ::= ArtemisDevice name
  scheduler ::= Scheduler
  applications ::= ApplicationManager scheduler
  scheduler.add_job
      SynchronizeJob device applications
  scheduler.run
