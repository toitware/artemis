// Copyright (C) 2023 Toitware ApS. All rights reserved.

import log
import .containers
import .scheduler

interface PinTriggerManager:
  /**
  Starts the trigger manager.

  Does 3 things:
  - clears all rtc pin configurations, so that the pins can be used normally.
  - triggers all jobs that were triggered by pins.
  - starts watching pins that are used to trigger jobs.
  */
  start jobs/List --scheduler/Scheduler --logger/log.Logger -> none

  /**
  Sets up pin triggers for the given $job.

  If the $job is already watched by this manager, updates the watchers
    possibly removing the job from the watch-list if it doesn't have any
    pin triggers anymore.

  If the $job is not known to this manager, adds it to the watch-list if
    it has pin triggers. If the job isn't triggered or running yet, then
    also sets up watchers.
  */
  update-job job/ContainerJob -> none


  /**
  Rearms the watchers for the given $job if it has pin triggers.
  */
  rearm-job job/ContainerJob -> none

  /**
  Prepares the system for waking up from deep sleep, if any of the
    given jobs is triggered by a pin.
  */
  prepare-deep-sleep jobs/List -> none
