// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .device
import .jobs

class Scheduler:
  signal_ ::= SchedulerSignal_
  logger_/log.Logger
  device_/Device

  jobs_ ::= []
  jobs_ran_last_end_/Map

  constructor logger/log.Logger .device_:
    logger_ = logger.with_name "scheduler"
    jobs_ran_last_end_ = device_.jobs_ran_last_end_modifiable

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
      jobs_.do: jobs_ran_last_end_[it.name] = it.scheduler_ran_last_.us
      stop_all_jobs_
      // For now, we only update the flash bucket when we're shutting down.
      // This means that if we lose power or hit an exceptional case, we
      // will reschedule all jobs.
      critical_do: device_.jobs_ran_last_end_update jobs_ran_last_end_

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
    jobs_ran_last_end_.remove job.name

  on_job_started job/Job -> none:
    job.scheduler_ran_after_boot_ = true
    if not job.period_excludes_running: record_ran_last_ job
    logger_.info "job started" --tags={"job": job}
    signal_.awaken

  on_job_ready job/Job -> none:
    signal_.awaken

  on_job_stopped job/Job -> none:
    if job.period_excludes_running: record_ran_last_ job
    else: update_ran_last_ job
    logger_.info "job stopped" --tags={"job": job}
    signal_.awaken

  record_ran_last_ job/Job -> none:
    last := JobTime.now - job.schedule_jitter
    job.scheduler_ran_last_ = last

  update_ran_last_ job/Job -> none:
    // For periodic jobs where the time spent running
    // is included in the period, we need to adjust
    // the last run information after the job has
    // stopped to account for long runs that continue
    // into the next period.
    assert: not job.period_excludes_running
    period := job.period
    if not period: return
    // Check if the elapsed run time exceeded the period.
    // If not, no updates are necessary.
    now := JobTime.now
    last := job.scheduler_ran_last_
    elapsed := last.to now
    if elapsed <= period: return
    // Compute the missed number of periods and use it
    // to update the last run to fit in the last period.
    missed := elapsed.in_ns / period.in_ns
    last = last + period * missed
    job.scheduler_ran_last_ = last

  has_running_jobs_ -> bool:
    return jobs_.any: | job/Job |
      job.is_running and not job.is_background

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
