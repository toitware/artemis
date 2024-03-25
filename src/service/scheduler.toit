// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import .device
import .jobs
import .watchdog
import .time

class Scheduler:
  static MAX-WAIT-DURATION/Duration ::= Duration --s=(WatchdogManager.TIMEOUT-SCHEDULER-S - 2)

  signal_ ::= SchedulerSignal_
  logger_/log.Logger
  device_/Device
  runlevel_/int := Job.RUNLEVEL-CRITICAL

  jobs_ ::= []

  constructor logger/log.Logger .device_:
    logger_ = logger.with-name "scheduler"

  runlevel -> int:
    return runlevel_

  run -> JobTime:
    now "Scheduler started"
    assert: not jobs_.is-empty
    try:
      dog := WatchdogManager.transition-to WatchdogManager.STATE-SCHEDULER
      while true:
        dog.feed
        now := JobTime.now
        next := start-due-jobs_ now
        if has-running-jobs_:
          // Wait until we need to run the next job. This is scheduled
          // for when JobTime.now reaches 'next'. Wake up earlier if the
          // jobs change by waiting on the signal.

          if not next or (now.to next) > MAX-WAIT-DURATION:
            // Shorten the wait time so we feed the dog in time.
            next = now + MAX-WAIT-DURATION

          signal_.wait next
        else:
          WatchdogManager.transition-to WatchdogManager.STATE_STOP
          return schedule-wakeup_ now
    finally:
      critical-do: transition --runlevel=Job.RUNLEVEL-STOP

  add-jobs jobs/List -> none:
    jobs.do: add-job it

  add-job job/Job -> none:
    job.scheduler_ = this
    jobs_.add job
    signal_.awaken

  delay-job job/Job --until/JobTime -> none:
    job.scheduler-delayed-until_ = until
    signal_.awaken

  remove-job job/Job -> none:
    job.stop
    jobs_.remove job

  transition --runlevel/int --timeout=(Duration --s=2) -> none:
    now "Transition to runlevel $runlevel"
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

  wait deadline/JobTime -> none:
    deadline-monotonic := deadline.to-monotonic-us
    try-await --deadline=deadline-monotonic: awakened_
    awakened_ = false
