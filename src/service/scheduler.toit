// Copyright (C) 2022 Toitware ApS. All rights reserved.

abstract class Job:
  task_/Task? := null
  last_run_/SchedulerTime? := null

  last_run -> SchedulerTime?:
    return last_run_

  abstract schedule now/SchedulerTime -> SchedulerTime?
  abstract run -> none

  start now/SchedulerTime -> none:
    if task_: return
    task_ = task::
      try:
        catch --trace: run
      finally:
        // TODO(kasper): Sometimes it makes more sense to set the
        // last run timestamp to the starting time ($now).
        last_run_ = SchedulerTime.now
        task_ = null
        // TODO(kasper): Tell scheduler that the state has changed.

  stop -> none:
    if not task_: return
    task_.cancel
    // TODO(kasper): Should we wait until the task is done?

class Scheduler:
  static instance := Scheduler
  jobs_ := []

  run -> none:
    while true:
      now := SchedulerTime.now
      // TODO(kasper): Stop jobs?
      next := run_due_jobs_ now
      // TODO(kasper): Return when we're all idle.
      if not next: next = now + (Duration --ms=500)
      sleep (now.to next)

  add_job job/Job -> none:
    jobs_.add job
    // TODO(kasper): Tell scheduler that the state has changed.

  remove_job job/Job -> none:
    jobs_ = jobs_.filter: not identical it job

  run_due_jobs_ now/SchedulerTime -> SchedulerTime?:
    first/SchedulerTime? := null
    jobs_.do: | job/Job |
      next ::= job.schedule now
      if not next: continue.do
      if next <= now:
        job.start now
      else if (not first or next < first):
        first = next
    return first

// TODO(kasper): What is a good name for this?
class SchedulerTime:
  us_/int

  constructor .us_:

  constructor.now:
    us_ = Time.monotonic_us

  operator <= other/SchedulerTime -> bool:
    return us_ <= other.us_

  operator < other/SchedulerTime -> bool:
    return us_ < other.us_

  operator + duration/Duration -> SchedulerTime:
    return SchedulerTime us_ + duration.in_us

  to other/SchedulerTime -> Duration:
    return Duration --us=other.us_ - us_
