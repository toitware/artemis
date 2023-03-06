// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .scheduler

abstract class Job:
  name/string

  // These fields are manipulated by the scheduler. They are
  // put here to avoid having a separate map to associate extra
  // information with jobs.
  scheduler_/Scheduler? := null
  scheduler_last_run_/JobTime? := null

  constructor .name:

  abstract is_running -> bool

  abstract schedule now/JobTime last/JobTime? -> JobTime?

  schedule_wakeup now/JobTime last/JobTime? -> JobTime?:
    return schedule now last

  abstract start now/JobTime -> none
  abstract stop -> none

  stringify -> string:
    return name

abstract class TaskJob extends Job:
  task_/Task? := null

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
        scheduler_.on_job_stopped this

  stop -> none:
    if not task_: return
    task_.cancel

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
  us_/int

  constructor .us_:

  constructor.now:
    us_ = Time.monotonic_us

  operator <= other/JobTime -> bool:
    return us_ <= other.us_

  operator < other/JobTime -> bool:
    return us_ < other.us_

  operator + duration/Duration -> JobTime:
    return JobTime us_ + duration.in_us

  to other/JobTime -> Duration:
    return Duration --us=other.us_ - us_

  to_monotonic_us -> int:
    return us_

  compare_to other/JobTime -> int:
    return us_.compare_to other.us_

  compare_to other/JobTime [--if_equal] -> int:
    return us_.compare_to other.us_ --if_equal=if_equal
