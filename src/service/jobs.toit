// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .scheduler

abstract class Job:
  scheduler_/Scheduler? := null
  task_/Task? := null
  last_run_/JobTime? := null

  last_run -> JobTime?:
    return last_run_

  abstract schedule now/JobTime -> JobTime?
  abstract run -> none

  start now/JobTime -> none:
    if task_: return
    task_ = task::
      try:
        catch --trace: run
      finally:
        // TODO(kasper): Sometimes it makes more sense to set the
        // last run timestamp to the starting time ($now).
        last_run_ = JobTime.now
        task_ = null
        scheduler_.awaken

  stop -> none:
    if not task_: return
    task_.cancel
    // TODO(kasper): Should we wait until the task is done?

class JobTime:
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
