// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import .jobs

class Scheduler:
  jobs_ := []
  signal_ ::= SchedulerSignal_
  logger_/log.Logger

  constructor logger/log.Logger:
    logger_ = logger.with_name "scheduler"

  run -> none:
    try:
      while true:
        now := JobTime.now
        // TODO(kasper): Stop jobs?
        next := run_due_jobs_ now
        // TODO(kasper): Return when we're all idle.
        if not next: next = now + (Duration --ms=500)
        signal_.wait next
    finally:
      jobs_.do: it.stop

  add_jobs jobs/List -> none:
    jobs.do: add_job it

  add_job job/Job -> none:
    job.scheduler_ = this
    jobs_.add job
    signal_.awaken

  remove_job job/Job -> none:
    jobs_ = jobs_.filter: not identical it job

  on_job_started job/Job -> none:
    logger_.info "job started" --tags={"job": job.stringify}
    signal_.awaken

  on_job_ready job/Job -> none:
    signal_.awaken

  on_job_stopped job/Job -> none:
    logger_.info "job stopped" --tags={"job": job.stringify}
    signal_.awaken

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
