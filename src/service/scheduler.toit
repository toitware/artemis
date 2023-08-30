// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .device
import .jobs

class Scheduler:
  signal_ ::= SchedulerSignal_
  logger_/log.Logger
  device_/Device
  runlevel_/int := Job.RUNLEVEL-SAFE

  jobs_ ::= []
  jobs-state-initial_/Map

  constructor logger/log.Logger .device_:
    logger_ = logger.with-name "scheduler"
    jobs-state-initial_ = device_.scheduler-jobs-state

  runlevel -> int:
    return runlevel_

  run -> JobTime:
    assert: not jobs_.is-empty
    try:
      while true:
        now := JobTime.now
        next := start-due-jobs_ now
        if has-running-jobs_:
          // Wait until we need to run the next job. This is scheduled
          // for when JobTime.now reaches 'next'. Wake up earlier if the
          // jobs change by waiting on the signal.
          signal_.wait next
        else:
          return schedule-wakeup_ now
    finally:
      critical-do:
        transition --runlevel=Job.RUNLEVEL-STOP
        // For now, we only update the storage bucket when we're
        // shutting down. This means that if hit an exceptional
        // case, we will reschedule all jobs.
        jobs-state := {:}
        jobs_.do: | job/Job |
          ran-last := job.scheduler-ran-last_
          delayed-until := job.scheduler-delayed-until_
          if not ran-last and not delayed-until: continue.do
          jobs-state[job.name] = ran-last
              // The common case is that we do not have delayed-until,
              ? delayed-until ? [ran-last.us, delayed-until.us] : ran-last.us
              // but we typically do have ran-last.
              : [null, delayed-until.us]
        device_.scheduler-jobs-state-update jobs-state

  add-jobs jobs/List -> none:
    jobs.do: add-job it

  add-job job/Job -> none:
    job.scheduler_ = this
    entry := jobs-state-initial_.get job.name
    if entry is List:
      ran-last/int? := entry[0]
      delayed-until/int := entry[1]
      job.scheduler-ran-last_ = ran-last and (JobTime ran-last)
      job.scheduler-delayed-until_ = JobTime delayed-until
    else:
      job.scheduler-ran-last_ = entry and (JobTime entry)
      job.scheduler-delayed-until_ = null
    jobs_.add job
    signal_.awaken

  delay-job job/Job --until/JobTime -> none:
    job.scheduler-delayed-until_ = until
    signal_.awaken

  remove-job job/Job -> none:
    job.stop
    jobs_.remove job

  transition --runlevel/int --timeout=(Duration --s=2) -> none:
    existing := runlevel_
    runlevel_ = runlevel
    if runlevel > existing:
      logger_.info "runlevel increasing" --tags={"runlevel": runlevel}
      signal_.awaken
    else if runlevel < existing:
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        with-timeout timeout:
          jobs_.do: | job/Job |
            // Stop all running jobs that have a too high runlevel,
            // one by one. Calling $Job.stop waits until the the
            // job is actually stopped and the scheduler has been
            // notified through a call to $on_job_stopped.
            if job.is-running and job.runlevel > runlevel: job.stop
        logger_.info "runlevel decreasing" --tags={"runlevel": runlevel}
        return
      logger_.warn "runlevel decreasing timed out" --tags={"runlevel": runlevel}

  on-job-started job/Job -> none:
    job.scheduler-ran-last_ = JobTime.now
    job.scheduler-delayed-until_ = null
    logger_.info "job started" --tags={"job": job}
    signal_.awaken

  on-job-stopped job/Job -> none:
    job.scheduler-ran-last_ = job.schedule-tune job.scheduler-ran-last_
    logger_.info "job stopped" --tags={"job": job}
    signal_.awaken

  on-job-updated -> none:
    signal_.awaken

  has-running-jobs_ -> bool:
    return jobs_.any: | job/Job |
      job.is-running and not job.is-background

  start-due-jobs_ now/JobTime -> JobTime?:
    first/JobTime? := null
    jobs_.do: | job/Job |
      if job.is-running or job.runlevel > runlevel_: continue.do
      next ::= job.schedule now job.scheduler-ran-last_
      if not next: continue.do
      if next <= now:
        job.start
      else if (not first or next < first):
        first = next
    return first

  schedule-wakeup_ now/JobTime -> JobTime:
    first/JobTime? := null
    jobs_.do: | job/Job |
      // We don't wake up just for the sake of background
      // jobs, so filter them out.
      if job.is-background: continue.do
      next := job.schedule now job.scheduler-ran-last_
      if next and (not first or next < first):
        first = next
    return first or now + (Duration --m=1)

// TODO(kasper): Can we use a standard monitor for this?
monitor SchedulerSignal_:
  awakened_ := false

  awaken -> none:
    awakened_ = true

  wait deadline/JobTime? -> none:
    deadline-monotonic := deadline ? deadline.to-monotonic-us : null
    try-await --deadline=deadline-monotonic: awakened_
    awakened_ = false
