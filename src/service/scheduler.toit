// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .device
import .jobs

class Scheduler:
  signal_ ::= SchedulerSignal_
  logger_/log.Logger
  device_/Device
  runlevel_/int := Job.RUNLEVEL_SAFE

  jobs_ ::= []
  jobs_state_initial_/Map

  constructor logger/log.Logger .device_:
    logger_ = logger.with_name "scheduler"
    jobs_state_initial_ = device_.scheduler_jobs_state

  runlevel -> int:
    return runlevel_

  run -> JobTime:
    assert: not jobs_.is_empty
    try:
      while true:
        now := JobTime.now
        next := start_due_jobs_ now
        if has_running_jobs_:
          // Wait until we need to run the next job. This is scheduled
          // for when JobTime.now reaches 'next'. Wake up earlier if the
          // jobs change by waiting on the signal.
          signal_.wait next
        else:
          return schedule_wakeup_ now
    finally:
      critical_do:
        transition --runlevel=Job.RUNLEVEL_STOP
        // For now, we only update the storage bucket when we're
        // shutting down. This means that if hit an exceptional
        // case, we will reschedule all jobs.
        jobs_state := {:}
        jobs_.do: | job/Job |
          ran_last := job.scheduler_ran_last_
          delayed_until := job.scheduler_delayed_until_
          if not ran_last and not delayed_until: continue.do
          jobs_state[job.name] = ran_last
              // The common case is that we do not have delayed-until,
              ? delayed_until ? [ran_last.us, delayed_until.us] : ran_last.us
              // but we typically do have ran-last.
              : [null, delayed_until.us]
        device_.scheduler_jobs_state_update jobs_state

  add_jobs jobs/List -> none:
    jobs.do: add_job it

  add_job job/Job -> none:
    job.scheduler_ = this
    entry := jobs_state_initial_.get job.name
    if entry is List:
      ran_last/int? := entry[0]
      delayed_until/int := entry[1]
      job.scheduler_ran_last_ = ran_last and (JobTime ran_last)
      job.scheduler_delayed_until_ = JobTime delayed_until
    else:
      job.scheduler_ran_last_ = entry and (JobTime entry)
      job.scheduler_delayed_until_ = null
    jobs_.add job
    signal_.awaken

  delay_job job/Job --until/JobTime -> none:
    job.scheduler_delayed_until_ = until
    signal_.awaken

  remove_job job/Job -> none:
    job.stop
    jobs_.remove job

  transition --runlevel/int --timeout=(Duration --s=2) -> none:
    existing := runlevel_
    runlevel_ = runlevel
    if runlevel > existing:
      logger_.info "runlevel increasing" --tags={"runlevel": runlevel}
      signal_.awaken
    else if runlevel < existing:
      catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout timeout:
          jobs_.do: | job/Job |
            // Stop all running jobs that have a too high runlevel,
            // one by one. Calling $Job.stop waits until the the
            // job is actually stopped and the scheduler has been
            // notified through a call to $on_job_stopped.
            if job.is_running and job.runlevel > runlevel: job.stop
        logger_.info "runlevel decreasing" --tags={"runlevel": runlevel}
        return
      logger_.warn "runlevel decreasing timed out" --tags={"runlevel": runlevel}

  on_job_started job/Job -> none:
    job.scheduler_ran_after_boot_ = true
    job.scheduler_ran_last_ = JobTime.now
    job.scheduler_delayed_until_ = null
    logger_.info "job started" --tags={"job": job}
    signal_.awaken

  on_job_stopped job/Job -> none:
    job.scheduler_ran_last_ = job.schedule_tune job.scheduler_ran_last_
    logger_.info "job stopped" --tags={"job": job}
    signal_.awaken

  on_job_updated -> none:
    signal_.awaken

  has_running_jobs_ -> bool:
    return jobs_.any: | job/Job |
      job.is_running and not job.is_background

  start_due_jobs_ now/JobTime -> JobTime?:
    first/JobTime? := null
    jobs_.do: | job/Job |
      if job.is_running: continue.do
      next ::= job.schedule now job.scheduler_ran_last_
      if not next: continue.do
      if next <= now:
        job.start
      else if (not first or next < first):
        first = next
    return first

  schedule_wakeup_ now/JobTime -> JobTime:
    first/JobTime? := null
    jobs_.do: | job/Job |
      // We don't wake up just for the sake of background
      // jobs, so filter them out.
      if job.is_background: continue.do
      next := job.schedule now job.scheduler_ran_last_
      if next and (not first or next < first):
        first = next
    return first or now + (Duration --m=1)

// TODO(kasper): Can we use a standard monitor for this?
monitor SchedulerSignal_:
  awakened_ := false

  awaken -> none:
    awakened_ = true

  wait deadline/JobTime? -> none:
    deadline_monotonic := deadline ? deadline.to_monotonic_us : null
    try_await --deadline=deadline_monotonic: awakened_
    awakened_ = false
