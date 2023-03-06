// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import .jobs

class Scheduler:
  jobs_ := []
  signal_ ::= SchedulerSignal_
  logger_/log.Logger

  constructor logger/log.Logger:
    logger_ = logger.with_name "scheduler"

  run -> JobTime:
    assert: not jobs_.is_empty
    try:
      while true:
        now := JobTime.now
        next := run_due_jobs_ now
        if has_running_jobs_:
          signal_.wait next
        else:
          return schedule_wakeup_ now
    finally:
      stop_all_jobs_

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
    job.scheduler_last_run_ = JobTime.now
    logger_.info "job stopped" --tags={"job": job.stringify}
    signal_.awaken

  has_running_jobs_ -> bool:
    return jobs_.any: | job/Job | job.is_running

  run_due_jobs_ now/JobTime -> JobTime?:
    first/JobTime? := null
    jobs_.do: | job/Job |
      if job.is_running: continue.do
      next ::= job.schedule now job.scheduler_last_run_
      if not next: continue.do
      if next <= now:
        job.start now
      else if (not first or next < first):
        first = next
    return first

  schedule_wakeup_ now/JobTime -> JobTime:
    first/JobTime? := null
    jobs_.do: | job/Job |
      next ::= job.schedule_wakeup now job.scheduler_last_run_
      if next and (not first or next < first):
        first = next
    return first or now + (Duration --m=1)

  stop_all_jobs_ -> none:
    jobs_.do: it.stop
    deadline := JobTime.now + (Duration --s=5)
    while has_running_jobs_ and JobTime.now < deadline:
      signal_.wait deadline

monitor SchedulerSignal_:
  awakened_ := false

  awaken -> none:
    awakened_ = true

  wait deadline/JobTime? -> none:
    deadline_monotonic := deadline ? deadline.to_monotonic_us : null
    try_await --deadline=deadline_monotonic: awakened_
    awakened_ = false
