// Copyright (C) 2022 Toitware ApS. All rights reserved.

import monitor
import .scheduler

abstract class Job:
  static RUNLEVEL-STOP     ::= 0
  static RUNLEVEL-SAFE     ::= 1
  static RUNLEVEL-CRITICAL ::= 2
  static RUNLEVEL-NORMAL   ::= 3

  name/string

  // These fields are manipulated by the scheduler. They are
  // put here to avoid having a separate map to associate extra
  // information with jobs.
  scheduler_/Scheduler? := null
  scheduler-ran-last_/JobTime? := null

  // TODO(kasper): Maybe this should be called run-after? The
  // way this interacts with the other triggers isn't super
  // clear, so maybe this should be passed to $schedule like
  // we do with last? You could argue that we should do the
  // same with has_run_after_boot.
  scheduler-delayed-until_/JobTime? := null

  constructor .name:

  abstract is-running -> bool
  is-background -> bool: return false

  runlevel -> int: return RUNLEVEL-NORMAL
  stringify -> string: return name

  abstract schedule now/JobTime last/JobTime? -> JobTime?

  schedule-tune last/JobTime -> JobTime:
    return last

  abstract start -> none
  abstract stop -> none

  /**
  State that survives deep sleeps.

  The returned value must be a JSON-serializable object. It is given to
    to the job before the scheduler makes any scheduling decision.

  # Inheritance
  Subclasses are allowed to extend the state with additional information.
  Before calling $set-saved-deep-sleep-state of this object they must restore
    the original value.
  */
  deep-sleep-state -> any:
    ran-last := scheduler-ran-last_
    delayed-until := scheduler-delayed-until_
    if not ran-last and not delayed-until:
      return null
    if ran-last and not delayed-until:
      // The most common case.
      return ran-last.us
    return [ran-last and ran-last.us, delayed-until and delayed-until.us]

  /**
  Sets the state that was saved by the job before a deep sleep.
  */
  set-saved-deep-sleep-state state/any -> none:
    if not state: return
    if state is List:
      ran-last-us := state[0]
      delayed-until-us := state[1]
      scheduler-ran-last_ = ran-last-us and JobTime ran-last-us
      scheduler-delayed-until_ = delayed-until-us and JobTime delayed-until-us
    else:
      scheduler-ran-last_ = JobTime state

  // If a periodic job runs longer than its period, it is beneficial
  // to delay starting the job again until it gets through the period
  // it just started. This helper achieves that by tuning the last
  // ran timestamp and moving it into the current period.
  static schedule-tune-periodic last/JobTime period/Duration? -> JobTime:
    if not period or period.is-zero: return last
    elapsed := last.to JobTime.now
    if elapsed <= period: return last
    // Compute the missed number of periods and use it
    // to update the last run to fit in the last period.
    missed := elapsed.in-ns / period.in-ns
    last = last + period * missed
    return last

abstract class TaskJob extends Job:
  task_/Task? := null
  latch_/monitor.Latch? := null

  constructor name/string:
    super name

  is-running -> bool:
    return task_ != null

  abstract run -> none

  start -> none:
    if task_: return
    task_ = task::
      try:
        catch --trace:
          scheduler_.on-job-started this
          run
      finally:
        task_ = null
        latch := latch_
        latch_ = null
        // It is possible that this task has been canceled,
        // so to allow monitor operations in this shutdown
        // sequence, we run the rest in a critical section.
        critical-do:
          scheduler_.on-job-stopped this
          if latch: latch.set null

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

  is-background -> bool:
    // Periodic jobs do not want to cause device
    // wakeups or block the device from going to
    // sleep. They just run on their schedule when
    // the device is awake anyway.
    return true

  schedule now/JobTime last/JobTime? -> JobTime?:
    if not last: return now
    return last + period_

  schedule-tune last/JobTime -> JobTime:
    // If running the periodic task took a long time, we tune
    // the schedule and postpone the next run by making it
    // start at the beginning of the next period instead of now.
    return Job.schedule-tune-periodic last period_

// TODO(kasper): Get rid of this again. It was originally
// implemented to have one place to handle problems arising
// from resets to the monotonic clock, but I think we can
// handle this in a nicer way elsewhere.
class JobTime implements Comparable:
  us/int

  constructor .us:

  constructor.now:
    us = time-now-us_

  operator <= other/JobTime -> bool:
    return us <= other.us

  operator < other/JobTime -> bool:
    return us < other.us

  operator >= other/JobTime -> bool:
    return us >= other.us

  operator > other/JobTime -> bool:
    return us > other.us

  operator + duration/Duration -> JobTime:
    return JobTime us + duration.in-us

  operator - duration/Duration -> JobTime:
    return JobTime us - duration.in-us

  to other/JobTime -> Duration:
    return Duration --us=other.us - us

  to-monotonic-us -> int:
    return Time.monotonic-us + (us - time-now-us_)

  compare-to other/JobTime -> int:
    return us.compare-to other.us

  compare-to other/JobTime [--if-equal] -> int:
    return us.compare-to other.us --if-equal=if-equal

// --------------------------------------------------------------------------

time-now-us_ -> int:
  #primitive.core.get-system-time
