// Copyright (C) 2023 Toitware ApS. All rights reserved.

import esp32
import gpio
import gpio.touch as gpio
import log
import monitor

// --------------------------------------------------------------------------
// The Artemis package has temporarily been copied from the open
// source repository:
//
// https://github.com/toitware/toit-artemis/blob/main/src/
//
// When the API changes have solidified, the copied directory
// will be deleted in this repository and the new published
// version will be used instead.

// WAS: import artemis show Trigger
import ..pkg-artemis-src-copy.artemis show Trigger

import ..containers
import ..scheduler

class Watcher:
  gpio-pin/gpio.Pin
  touch-pin/gpio.Touch?
  task/Task

  constructor .gpio-pin .task:
    touch-pin = null

  constructor.touch .gpio-pin .touch-pin .task:

class PinTriggerManager:
  scheduler_/Scheduler
  logger_/log.Logger
  // A list of watchers for each level.
  // watchers[0] watch for level 0.
  // watchers[1] watch for level 1.
  pin-trigger-watchers_/List ::= [{:}, {:}]  // List of Map<int, Watcher>
  // Watchers for touch events.
  touch-trigger-watchers_/Map ::= {:}  // Map<int, Watcher>
  // Any job that has pin-triggers is stored here.
  // If a job is already triggered or running, then it doesn't need any watchers,
  // but it's still stored here.
  watched-jobs_/Map := {:}  // Map<string, ContainerJob>
  // The pin mask that triggered a wakeup.
  startup-triggers_/int := 0
  setup-watcher-mutex_ ::= monitor.Mutex
  touch-mutex_ ::= monitor.Mutex

  constructor .scheduler_ .logger_:

  /**
  Starts the trigger manager.

  Does 3 things:
  - clears all rtc pin configurations, so that the pins can be used normally.
  - triggers all jobs that were triggered by pins.
  - starts watching pins that are used to trigger jobs.
  */
  start jobs/List -> none:
    // Handle the triggers first. This way we mark jobs that need to
    // run as triggered before we start watching the pins (thus avoiding
    // setting up watchers).
    // TODO(florian): we should also see when jobs are run on-boot, in which
    // case they are also "triggered".
    handle-external-triggers_ jobs
    jobs.do: watch_ it

  /**
  Updates the pin trigger watchers based on the current state of
    the jobs.

  Runs through all watched jobs and make sure that we are running
    the correct watchers.
  */
  update_ -> none:
    BOTH ::= -1
    needed-watchers := {:}
    needed-touch-watchers := {}

    watched-jobs_.do --values: | job/ContainerJob |
      if job.is-running or job.is-triggered_: continue.do
      job.do --trigger-gpio-levels: | pin level/int |
        // If not present set to the current level.
        // If present, update to BOTH if we have already seen the other level.
        needed-watchers.update pin
            --if-absent=level
            : it != level ? BOTH : level

      if job.has-touch-triggers:
        needed-touch-watchers.add-all job.touch-triggers

    // Close all watchers we don't need anymore.
    // If we are really unlucky we might close a pin that we
    // need to watch (the opposite level), but that should be really
    // rare.
    2.repeat: | level/int |
      watchers/Map := pin-trigger-watchers_[level]
      other-watchers/Map := pin-trigger-watchers_[level ^ 1]
      watchers.filter --in-place: | pin/int watcher/Watcher |
        needed-level := needed-watchers.get pin
        is-needed := needed-level == BOTH or needed-level == level
        if not is-needed:
          watcher.task.cancel
          if not other-watchers.contains pin:
            watcher.gpio-pin.close
        is-needed

    touch-trigger-watchers_.filter --in-place: | pin/int watcher/Watcher |
      is-needed := needed-touch-watchers.contains pin
      if not is-needed:
        watcher.task.cancel
        watcher.touch-pin.close
        watcher.gpio-pin.close
      is-needed

    needed-watchers.do: | pin/int level/int |
      if level == BOTH:
        setup-watcher_ pin --level=0
        setup-watcher_ pin --level=1
      else:
        setup-watcher_ pin --level=level

    // If a touch pin is also an external trigger, then the setup_touch_watcher_
    // will fail.
    // Not sure if we should do more here.
    needed-touch-watchers.do: setup-touch-watcher_ it

  /**
  Sets up pin triggers for the given $job.

  If the $job is already watched by this manager, updates the watchers
    possibly removing the job from the watch-list if it doesn't have any
    pin triggers anymore.

  If the $job is not known to this manager, adds it to the watch-list if
    it has pin triggers. If the job isn't triggered or running yet, then
    also sets up watchers.
  */
  update-job job/ContainerJob -> none:
    if watched-jobs_.contains job.name:
      if not job.has-pin-triggers:
        watched-jobs_.remove job.name
      // We don't have any information of what the job was
      // previously watching. Run a "global" update.
      update_
      return

    watch_ job

  /**
  Rearms the watchers for the given $job if it has pin triggers.
  */
  rearm-job job/ContainerJob -> none:
    watch_ job

  /**
  Starts watching the pins of the given job.

  Only adds additional watchers, and never removes any. For
    removal a call to $update_ is needed.
  */
  watch_ job/ContainerJob -> none:
    if job.is-triggered_: return
    if job.is-running: return
    if not job.has-pin-triggers: return

    watched-jobs_[job.name] = job
    job.do --trigger-gpio-levels: | pin level/int |
      setup-watcher_ pin --level=level
    job.do --trigger-touch-pins: | pin/int |
      setup-touch-watcher_ pin

  /**
  Informs the manager that a pin has been triggered.

  In response triggers the watched jobs that wait for this pin.
  Before running the jobs disables the watchers that aren't needed
    anymore so that the jobs can use the pins.
  */
  notify-pin pin-number/int --level/int?=null --touch/bool?=null:
    watched-jobs_.values.do: | job/ContainerJob |
      if not job.has-pin-triggers:
        // Should never happen.
        continue.do
      if job.is-running: continue.do
      if job.is-triggered_: continue.do
      is-triggered := (level and job.has-pin-trigger pin-number --level=level) or
                      (touch and job.has-touch-trigger pin-number)
      if is-triggered:
        tags := job.tags.copy
        tags["pin"] = pin-number
        if level: tags["level"] = level
        else: tags["touch"] = touch
        logger_.info "triggered by pin" --tags=tags
        encoded-trigger := touch
            ? Trigger.encode-touch pin-number
            : Trigger.encode-pin pin-number --level=level
        job.trigger encoded-trigger

    // We need a critical_do as `update_` might kill the currently running
    // task.
    critical-do:
      // Update the triggers before we wake up the job.
      // Otherwise the job might not be able to access the pin.
      update_
      scheduler_.on-job-updated

  /**
  Sets up a watcher for the given $pin-number and $level.

  If such a watcher already exists, does nothing.
  If the pin is not available reports an error on the logger.
  */
  setup-watcher_ pin-number/int --level/int -> none:
    setup-watcher-mutex_.do:
      exception := catch:
        correct-watcher := pin-trigger-watchers_[level].get pin-number
        if correct-watcher:
          return

        other-level := level ^ 1
        other-watcher := pin-trigger-watchers_[other-level].get pin-number

        gpio-pin/gpio.Pin? := ?
        if other-watcher:
          // Reuse the pin.
          gpio-pin = other-watcher.gpio-pin
        else:
          // Create a new pin.
          gpio-pin = gpio.Pin pin-number --input

        watch-task := task --background::
          catch:
            // If the pin gets closed from the outside the `wait_for` might
            // throw an exception.
            // TODO(florian): since we kill the watcher when the program
            // runs, we often end up in situations where the program
            // finishes and then starts the watcher again.
            // And since the level is high, it immediately triggers again.
            // We need to decide whether this is the expected behavior.
            gpio-pin.wait-for level
            notify-pin pin-number --level=level

        watcher := Watcher gpio-pin watch-task
        pin-trigger-watchers_[level][pin-number] = watcher

      if not exception: return
      tags := {
        "pin": pin-number,
        "level": level,
        "exception": exception,
      }
      logger_.error "failed to setup pin trigger" --tags=tags

  setup-touch-watcher_ pin-number/int -> none:
    setup-watcher-mutex_.do:
      if touch-trigger-watchers_.contains pin-number: return
      exception := catch:
        pin := gpio.Pin pin-number
        touch := gpio.Touch pin
        // TODO(florian): we want to get the threshold from a saved calibration.
        // TODO(florian): we should save the threshold the first time we do the
        // calibration.
        calibrate_ touch
        // TODO(florian): it would be much more efficient if touch events were
        // triggered by interrupts. However, at the very least, we should have
        // only one task watching all touch pins.
        watch-task := task --background::
          catch --trace:
            while true:
              data := touch.read --raw
              if data < touch.threshold:
                notify-pin pin-number --touch
                break
              sleep --ms=200

        watcher := Watcher.touch pin touch watch-task
        touch-trigger-watchers_[pin-number] = watcher

      if not exception: return
      tags := {
        "pin": pin-number,
        "exception": exception,
      }
      logger_.error "failed to setup touch trigger" --tags=tags

  calibrate_ touch/gpio.Touch -> none:
    TOUCH-CALIBRATION-SAMPLES ::= 16
    sum := 0
    TOUCH-CALIBRATION-SAMPLES.repeat: sum += touch.read --raw
    touch.threshold = sum * 2 / (3 * TOUCH-CALIBRATION-SAMPLES)
    logger_.info "calibrated touch" --tags={"pin": touch.pin.num, "threshold": touch.threshold}

  trigger-mask_ jobs/List --level/int -> int:
    mask := 0
    jobs.do: | job/ContainerJob |
      job.do --trigger-gpio-levels: | pin pin-level/int |
        if level == pin-level:
          mask |= 1 << pin
    return mask

  /**
  Prepares the system for waking up from deep sleep, if any of the
    given jobs is triggered by a pin.
  */
  prepare-deep-sleep jobs/List:
    // Note that we don't use the watched jobs, as one might have been triggered
    // and thus be removed from the list.

    // TODO(florian): do we have a way to abort shutting down, if we see a
    // triggered job? Otherwise we have a race condition...

    high-mask := trigger-mask_ jobs --level=1
    low-mask := trigger-mask_ jobs --level=0
    if high-mask != 0:
      // TODO(florian): only some pins are allowed.
      logger_.info "setting up external-wakeup trigger any high: $(%b high-mask)"
      esp32.enable-external-wakeup high-mask true
      if low-mask != 0:
        logger_.warn "pin triggers for low level are ignored"
    else if low-mask != 0:
      if low-mask.population-count > 1:
        logger_.warn "device will only wake up if all trigger pins are 0"
      logger_.info "setting up external-wakeup trigger all low: $(%b low-mask)"
      esp32.enable-external-wakeup low-mask false

    has-touch-triggers := jobs.any: | job/ContainerJob | job.has-touch-triggers

    if has-touch-triggers:
      esp32.enable-touchpad-wakeup

  handle-external-triggers_ jobs/List -> none:
    cause := esp32.wakeup-cause
    if cause != esp32.WAKEUP-UNDEFINED:
      // Wakeup from deep sleep.
      high-mask := trigger-mask_ jobs --level=1
      low-mask := trigger-mask_ jobs --level=0
      external-mask := high-mask != 0 ? high-mask : low-mask

      triggered-pins := esp32.ext1-wakeup-status external-mask
      touch-wakeup-pin := esp32.touchpad-wakeup-status  // -1 if not triggered by touch.

      job-was-triggered := false
      // If the high_mask isn't 0, then it wins over the low mask.
      jobs.do: | job/ContainerJob |
        job.do --trigger-gpio-levels: | pin level/int |
          pin-mask := 1 << pin
          if (triggered-pins & pin-mask) != 0:
            is-triggered := false
            if level == 1:
              // Level 1 wins over level 0.
              is-triggered = true
            else if high-mask == 0:
              // Level 0 is only triggered if there is no level 1.
              is-triggered = true
            if is-triggered:
              job-was-triggered = true
              job.trigger (Trigger.encode-pin pin --level=level)
              tags := job.tags.copy
              tags["pin"] = pin
              tags["level"] = level
              logger_.info "triggered by pin" --tags=tags
        job.do --trigger-touch-pins: | pin/int |
          if touch-wakeup-pin == pin:
            job-was-triggered = true
            job.trigger (Trigger.encode-touch pin)
            tags := job.tags.copy
            tags["pin"] = pin
            logger_.info "triggered by touch" --tags=tags

      if job-was-triggered:
        scheduler_.on-job-updated
