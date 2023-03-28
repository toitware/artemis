// Copyright (C) 2023 Toitware ApS. All rights reserved.

import esp32
import gpio
import log

import .containers
import .scheduler

class Watcher:
  gpio_pin/gpio.Pin
  task/Task

  constructor .gpio_pin .task:

class PinTriggerManager:
  scheduler_/Scheduler
  logger_/log.Logger
  // A list of watchers for each level.
  // watchers[0] watch for level 0.
  // watchers[1] watch for level 1.
  pin_trigger_watchers_/List ::= [{:}, {:}]  // List of Map<int, Watcher>
  // Any job that has pin-triggers is stored here.
  // If a job is already triggered or running, then it doesn't need any watchers,
  // but it's still stored here.
  watched_jobs_/Map := {:}  // Map<string, ContainerJob>
  // The pin mask that triggered a wakeup.
  startup_triggers_/int := 0

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
    handle_external_triggers_ jobs
    jobs.do: watch_ it

  /**
  Updates the pin trigger watchers based on the current state of
    the jobs.

  Runs through all watched jobs and make sure that we are running
    the correct watchers.
  */
  update_ -> none:
    BOTH ::= -1
    needed_watchers := {:}
    watched_jobs_.do --values: | job/ContainerJob |
      if job.is_running or job.is_triggered_: continue.do
      job.trigger_pin_levels_.do: | pin level/int |
        needed_watchers.update
            pin
            --if_absent=level
            : it == level ? level : BOTH

    // Close all watchers we don't need anymore.
    // If we are really unlucky we might close a pin that we
    // need to watch (the opposite level), but that should be really
    // rare.
    2.repeat: | level/int |
      watchers/Map := pin_trigger_watchers_[level]
      other_watchers/Map := pin_trigger_watchers_[level ^ 1]
      watchers.filter --in_place: | pin/int watcher/Watcher |
        needed_level := needed_watchers.get pin
        is_needed := needed_level == BOTH or needed_level == level
        if not is_needed:
          watcher.task.cancel
          if not other_watchers.contains pin:
            watcher.gpio_pin.close
        is_needed

    needed_watchers.do: | pin/int level/int |
      if level == BOTH:
        setup_watcher_ pin --level=0
        setup_watcher_ pin --level=1
      else:
        setup_watcher_ pin --level=level

  /**
  Sets up pin triggers for the given $job.

  If the $job is already watched by this manager, updates the watchers
    possibly removing the job from the watch-list if it doesn't have any
    pin triggers anymore.

  If the $job is not known to this manager, adds it to the watch-list if
    it has pin triggers. If the job isn't triggered or running yet, then
    also sets up watchers.
  */
  update_job job/ContainerJob -> none:
    if watched_jobs_.contains job.name:
      if not job.has_pin_triggers:
        watched_jobs_.remove job.name
      // We don't have any information of what the job was
      // previously watching. Run a "global" update.
      update_
      return

    watch_ job

  /**
  Rearms the watchers for the given $job if it has pin triggers.
  */
  rearm_job job/ContainerJob -> none:
    watch_ job

  /**
  Starts watching the pins of the given job.

  Only adds additional watchers, and never removes any. For
    removal a call to $update_ is needed.
  */
  watch_ job/ContainerJob -> none:
    if job.is_triggered_: return
    if job.is_running: return
    if not job.has_pin_triggers: return

    watched_jobs_[job.name] = job
    job.trigger_pin_levels_.do: | pin level/int |
      setup_watcher_ pin --level=level

  /**
  Informs the manager that a pin has been triggered.

  In response triggers the watched jobs that wait for this pin.
  Before running the jobs disables the watchers that aren't needed
    anymore so that the jobs can use the pins.
  */
  notify_pin pin_number/int --level/int:
    watched_jobs_.values.do: | job/ContainerJob |
      if not job.has_pin_triggers:
        // Should never happen.
        continue.do
      if job.is_running: continue.do
      if job.is_triggered_: continue.do
      if job.has_pin_trigger pin_number --level=level:
        tags := job.tags.copy
        tags["pin"] = pin_number
        tags["level"] = level
        logger_.info "triggered by pin" --tags=tags
        job.is_triggered_ = true
    // Update the triggers before we wake up the job.
    // Otherwise the job might not be able to access the pin.
    update_
    scheduler_.wake_up

  /**
  Sets up a watcher for the given $pin_number and $level.

  If such a watcher already exists, does nothing.
  If the pin is not available reports an error on the logger.
  */
  setup_watcher_ pin_number/int --level/int -> none:
    exception := catch:
      // TODO(florian): do we need to use a lock here?
      correct_watcher := pin_trigger_watchers_[level].get pin_number
      if correct_watcher:
        return

      other_level := level ^ 1
      other_watcher := pin_trigger_watchers_[other_level].get pin_number

      gpio_pin/gpio.Pin? := ?
      if other_watcher:
        // Reuse the pin.
        gpio_pin = other_watcher.gpio_pin
      else:
        // Create a new pin.
        gpio_pin = gpio.Pin pin_number --input

      watch_task := task --background::
        // TODO(florian): should we catch here?
        // In theory there should be nothing that could throw.
        // TODO(florian): since we kill the watcher when the program
        // runs, we often end up in situations where the program
        // finishes and then starts the watcher again.
        // And since the level is high, it immediately triggers again.
        // We need to decide whether this is the expected behavior.
        gpio_pin.wait_for level
        notify_pin pin_number --level=level

      watcher := Watcher gpio_pin watch_task
      pin_trigger_watchers_[level][pin_number] = watcher
    if exception:
      tags := {
        "pin": pin_number,
        "level": level,
        "exception": exception,
      }
      logger_.error "failed to setup pin trigger" --tags=tags

  trigger_mask_ jobs/List --level/int -> int:
    mask := 0
    jobs.do: | job/ContainerJob |
      if job.has_pin_triggers:
        job.trigger_pin_levels_.do: | pin pin_level/int |
          if level == pin_level:
            mask |= 1 << pin
    return mask

  /**
  Prepares the system for waking up from deep sleep, if any of the
    given jobs is triggered by a pin.
  */
  prepare_deep_sleep jobs/List:
    // Note that we don't use the watched jobs, as one might have been triggered
    // and thus be removed from the list.

    // TODO(florian): do we have a way to abort shutting down, if we see a
    // triggered job? Otherwise we have a race condition...

    high_mask := trigger_mask_ jobs --level=1
    low_mask := trigger_mask_ jobs --level=0
    if high_mask != 0:
      // TODO(florian): only some pins are allowed.
      logger_.info "setting up deepsleep trigger any high: $(%b high_mask)"
      esp32.enable_external_wakeup high_mask true
      if low_mask != 0:
        logger_.warn "pin triggers for low level are ignored"
    else if low_mask != 0:
      if low_mask.population_count > 1:
        logger_.warn "device will only wake up if all trigger pins are 0"
      logger_.info "setting up deepsleep trigger all low: $(%b low_mask)"
      esp32.enable_external_wakeup low_mask false

  handle_external_triggers_ jobs/List -> none:
    cause := esp32.wakeup_cause
    if cause != esp32.WAKEUP_UNDEFINED:
        // Wakeup from deepsleep.
      scheduler_.wake_up
      high_mask := trigger_mask_ jobs --level=1
      low_mask := trigger_mask_ jobs --level=0
      external_mask := high_mask != 0 ? high_mask : low_mask

      triggered_pins := esp32.ext1_wakeup_status external_mask

      // If the high_mask isn't 0, then it wins over the low mask.
      jobs.do: | job/ContainerJob |
        if job.has_pin_triggers:
          job.trigger_pin_levels_.do: | pin level/int |
            pin_mask := 1 << pin
            if (triggered_pins & pin_mask) != 0:
              is_triggered := false
              if level == 1:
                // Level 1 wins over level 0.
                is_triggered = true
              else if high_mask == 0:
                // Level 0 is only triggered if there is no level 1.
                is_triggered = true
              if is_triggered:
                job.is_triggered_ = true
                tags := job.tags.copy
                tags["pin"] = pin
                tags["level"] = level
                logger_.info "triggered by pin" --tags=tags
