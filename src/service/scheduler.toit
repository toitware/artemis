// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .jobs

class Scheduler:
  jobs_ := []
  signal_ ::= SchedulerSignal_

  awaken -> none:
    signal_.awaken

  run -> none:
    while true:
      now := JobTime.now
      // TODO(kasper): Stop jobs?
      next := run_due_jobs_ now
      // TODO(kasper): Return when we're all idle.
      if not next: next = now + (Duration --ms=500)
      signal_.wait next

  add_job job/Job -> none:
    job.scheduler_ = this
    jobs_.add job
    awaken

  remove_job job/Job -> none:
    jobs_ = jobs_.filter: not identical it job

  run_due_jobs_ now/JobTime -> JobTime?:
    first/JobTime? := null
    jobs_.do: | job/Job |
      next ::= job.schedule now
      if not next: continue.do
      if next <= now:
        job.start now
      else if (not first or next < first):
        first = next
    return first

monitor SchedulerSignal_:
  awakened_ := false

  awaken -> none:
    awakened_ = true

  wait deadline/JobTime? -> none:
    deadline_monotonic := deadline ? deadline.to_monotonic_us : null
    try_await --deadline=deadline_monotonic: awakened_
    awakened_ = false
