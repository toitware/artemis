// Copyright (C) 2022 Toitware ApS. All rights reserved.

import monitor
import .scheduler

abstract class Job:
  name/string

  // These fields are manipulated by the scheduler. They are
  // put here to avoid having a separate map to associate extra
  // information with jobs.
  scheduler_/Scheduler? := null
  scheduler_ran_last_/JobTime? := null
  scheduler_ran_after_boot_/bool := false

  constructor .name:

  abstract is_running -> bool

  has_run_after_boot -> bool:
    return scheduler_ran_after_boot_

  abstract schedule now/JobTime last/JobTime? -> JobTime?

  schedule_wakeup now/JobTime last/JobTime? -> JobTime?:
    return schedule now last

  abstract start now/JobTime -> none
  abstract stop -> none

  stringify -> string:
    return name

abstract class TaskJob extends Job:
  task_/Task? := null
  latch_/monitor.Latch? := null

  constructor name/string:
    super name

  is_running -> bool:
    return task_ != null

  abstract run -> none

  start now/JobTime -> none:
    if task_: return
    task_ = task::
      try:
        catch --trace:
          scheduler_.on_job_started this
          run
      finally:
        task_ = null
        latch := latch_
        latch_ = null
        // It is possible that this task has been canceled,
        // so to allow monitor operations in this shutdown
        // sequence, we run the rest in a critical section.
        critical_do:
          if latch: latch.set null
          scheduler_.on_job_stopped this

  stop -> none:
    if not task_: return
    // We're going to cancel the task, so check if
    // anyone else is waiting for it to stop. It is
    // rather unlikely, but it is cheap to test for.
    latch := latch_
    if not latch:
      latch = monitor.Latch
      latch_ = latch
    task_.cancel
    latch.get

abstract class PeriodicJob extends TaskJob:
  period_/Duration

  constructor name/string .period_:
    super name

  schedule now/JobTime last/JobTime? -> JobTime?:
    if not last: return now
    return last + period_

  schedule_wakeup now/JobTime last/JobTime? -> JobTime?:
    // Periodic jobs do not want to cause device
    // wakeups. They just run on their schedule
    // when the device is awake anyway.
    return null

// TODO(kasper): Get rid of this again. It was originally
// implemented to have one place to handle problems arising
// from resets to the monotonic clock, but I think we can
// handle this in a nicer way elsewhere.
class JobTime implements Comparable:
  us/int

  constructor .us:

  constructor.now:
    us = time_now_

  operator <= other/JobTime -> bool:
    return us <= other.us

  operator < other/JobTime -> bool:
    return us < other.us

  operator + duration/Duration -> JobTime:
    return JobTime us + duration.in_us

  to other/JobTime -> Duration:
    return Duration --us=other.us - us

  to_monotonic_us -> int:
    return Time.monotonic_us + (us - time_now_)

  compare_to other/JobTime -> int:
    return us.compare_to other.us

  compare_to other/JobTime [--if_equal] -> int:
    return us.compare_to other.us --if_equal=if_equal

// --------------------------------------------------------------------------

time_now_ -> int:
  #primitive.core.get_system_time
