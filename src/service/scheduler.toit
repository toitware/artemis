// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import system.storage

import .jobs

class Scheduler:
  signal_ ::= SchedulerSignal_
  logger_/log.Logger

  jobs_ ::= []
  jobs_bucket_/storage.Bucket
  jobs_ran_last_end_/Map

  constructor logger/log.Logger:
    logger_ = logger.with_name "scheduler"
    jobs_bucket_ = storage.Bucket.open --flash "toit.io/artemis/jobs"
    // TODO(kasper): Tag the map with the current monotonic clock 'phase',
    // so we know if we can use the use any found information.
    stored := jobs_bucket_.get "ran-last-end"
    jobs_ran_last_end_ = stored is Map ? stored.copy : {:}

  run -> JobTime:
    assert: not jobs_.is_empty
    try:
      while true:
        now := JobTime.now
        next := run_due_jobs_ now
        if has_running_jobs_:
          // Wait until we need to run the next job. This is scheduled
          // for when JobTime.now reaches 'next'. Wake up earlier if the
          // jobs change by waiting on the signal.
          signal_.wait next
        else:
          return schedule_wakeup_ now
    finally:
      stop_all_jobs_
      // For now, we only update the flash bucket when we're shutting down.
      // This means that if we lose power or hit an exceptional case, we
      // will reschedule all jobs.
      critical_do: jobs_bucket_["ran-last-end"] = jobs_ran_last_end_

  add_jobs jobs/List -> none:
    jobs.do: add_job it

  add_job job/Job -> none:
    job.scheduler_ = this
    last := jobs_ran_last_end_.get job.name
    job.scheduler_ran_last_ = last and (JobTime last)
    jobs_.add job
    signal_.awaken

  remove_job job/Job -> none:
    job.stop
    jobs_.remove job
    // TODO(kasper): This is a temporary measure to get
    // jobs to run again if re-installed. We should be
    // clearing whatever makes the run-on-install trigger
    // fire, but for now we trigger run-on-boot again.
    job.scheduler_ran_after_boot_ = false

  on_job_started job/Job -> none:
    job.scheduler_ran_after_boot_ = true
    logger_.info "job started" --tags={"job": job}
    signal_.awaken

  on_job_ready job/Job -> none:
    signal_.awaken

  on_job_stopped job/Job -> none:
    last := JobTime.now
    job.scheduler_ran_last_ = last
    jobs_ran_last_end_[job.name] = last.us
    logger_.info "job stopped" --tags={"job": job}
    signal_.awaken

  has_running_jobs_ -> bool:
    return jobs_.any: | job/Job | job.is_running

  run_due_jobs_ now/JobTime -> JobTime?:
    first/JobTime? := null
    jobs_.do: | job/Job |
      if job.is_running: continue.do
      next ::= job.schedule now job.scheduler_ran_last_
      if not next: continue.do
      if next <= now:
        job.start now
      else if (not first or next < first):
        first = next
    return first

  schedule_wakeup_ now/JobTime -> JobTime:
    first/JobTime? := null
    jobs_.do: | job/Job |
      next ::= job.schedule_wakeup now job.scheduler_ran_last_
      if next and (not first or next < first):
        first = next
    return first or now + (Duration --m=1)

  stop_all_jobs_ -> none:
    // Stop all running jobs, one by one. Calling $Job.stop waits
    // until the the job is actually stopped and the scheduler
    // has been notified through a call to $on_job_stopped.
    catch: with_timeout (Duration --s=5): jobs_.do: it.stop

// TODO(kasper): Can we use a standard monitor for this?
monitor SchedulerSignal_:
  awakened_ := false

  awaken -> none:
    awakened_ = true

  wait deadline/JobTime? -> none:
    deadline_monotonic := deadline ? deadline.to_monotonic_us : null
    try_await --deadline=deadline_monotonic: awakened_
    awakened_ = false
