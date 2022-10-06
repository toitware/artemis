// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .scheduler

abstract class Job:
  name/string
  scheduler_/Scheduler? := null
  task_/Task? := null
  last_run_/JobTime? := null

  constructor .name:

  abstract schedule now/JobTime -> JobTime?
  abstract run -> none

  last_run -> JobTime?:
    return last_run_

  stringify -> string:
    return name

  start now/JobTime -> none:
    if task_: return
    task_ = task::
      try:
        catch --trace:
          scheduler_.on_job_started this
          run
      finally:
        // TODO(kasper): Sometimes it makes more sense to set the
        // last run timestamp to the starting time ($now).
        last_run_ = JobTime.now
        task_ = null
        scheduler_.on_job_stopped this

  stop -> none:
    if not task_: return
    task_.cancel
    // TODO(kasper): Should we wait until the task is done?

abstract class PeriodicJob extends Job:
  period_/Duration

  constructor name/string .period_:
    super name

  schedule now/JobTime -> JobTime?:
    if not last_run: return now
    return last_run + period_

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
