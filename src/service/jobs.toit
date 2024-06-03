// Copyright (C) 2022 Toitware ApS. All rights reserved.

import monitor
import .scheduler

abstract class Job:
  static RUNLEVEL-STOP     ::= 0
  static RUNLEVEL-CRITICAL ::= 1
  static RUNLEVEL-PRIORITY ::= 2
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

  constructor .name state/any:
    set-scheduler-state_ state

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
  State that has to survive deep sleeps.

  The returned value must be a JSON-serializable object. It is later given to
    to the job before the scheduler makes any scheduling decision.

  # Inheritance
  Subclasses are allowed to extend the state with additional information.
  Before calling $set-scheduler-state_ of this object they must restore
    the original value.
  */
  scheduler-state -> any:
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
  See $state.
  */
  set-scheduler-state_ state/any -> none:
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

  constructor name/string saved-state/any:
    super name saved-state

  is-running -> bool:
    return task_ != null

  abstract run -> none

  start -> none:
    if task_: return
    task_ = task::
      try:
        // It is unlikely that we're already canceled at this
        // point, but it seems possible. Since we're going to
        // tell that scheduler that the job stopped, we need
        // to also make sure to tell it that it started.
        critical-do: scheduler_.on-job-started this
        catch --trace: run
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

// TODO(kasper): Get rid of this again. It was originally
// implemented to have one place to handle problems arising
// from resets to the monotonic clock, but I think we can
// handle this in a nicer way elsewhere.
class JobTime implements Comparable:
  us/int

  constructor .us:

  constructor.now:
    us = Time.monotonic-us

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

  compare-to other/JobTime -> int:
    return us.compare-to other.us

  compare-to other/JobTime [--if-equal] -> int:
    return us.compare-to other.us --if-equal=if-equal
