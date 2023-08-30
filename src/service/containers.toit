// Copyright (C) 2022 Toitware ApS. All rights reserved.

import gpio
import log
import reader show Reader SizedReader
import uuid

import system.containers

import .jobs
import .esp32.pin-trigger
import .scheduler
import ..shared.utils as utils

class ContainerManager:
  logger_/log.Logger
  scheduler_/Scheduler

  jobs_ ::= {:}           // Map<string, ContainerJob>
  images_ ::= {}          // Set<uuid.Uuid>
  images-bundled_ ::= {}  // Set<uuid.Uuid>
  pin-trigger-manager_/PinTriggerManager ::= ?

  constructor logger/log.Logger .scheduler_:
    logger_ = logger.with-name "containers"
    pin-trigger-manager_ = PinTriggerManager scheduler_ logger_
    containers.images.do: | image/containers.ContainerImage |
      images_.add image.id
      // TODO(kasper): It feels like a bit of a hack to determine
      // if an installed container image is bundled based on
      // whether or not it has a name.
      is-bundled := image.name != null
      if is-bundled: images-bundled_.add image.id

  load state/Map -> none:
    apps := state.get "apps" --if-absent=: return
    apps.do: | name description |
      id/uuid.Uuid? := null
      catch: id = uuid.parse (description.get ContainerJob.KEY-ID)
      if not id: continue.do
      job := create --name=name --id=id --description=description
      // TODO(kasper): We should be able to find all container
      // images used by the current state in flash, so it isn't
      // very clear how we should handle it if we cannot. Should
      // we drop such an app from the current state? Seems like
      // the right thing to do.
      if job:
        if job.trigger-boot_:
          job.trigger (encode-trigger-reason_ --boot)
        add_ job --message="load"

    // Mark containers that are needed by connections as runlevel safemode.
    // TODO(florian): should required containers be started on-demand?
    connections := state.get "connections"
    connections.do: | connection/Map |
      requires/List? := connection.get "requires"
      if requires:
        requires.do: | required-name/string |
          job := get --name=required-name
          if job: job.runlevel_ = Job.RUNLEVEL-SAFE

    pin-trigger-manager_.start jobs_.values

  setup-deep-sleep-triggers:
    non-delayed-jobs := jobs_.values.filter: | job/Job | job.scheduler-delayed-until_ == null
    pin-trigger-manager_.prepare-deep-sleep non-delayed-jobs

  get --name/string -> ContainerJob?:
    return jobs_.get name

  get --gid/int -> ContainerJob?:
    // TODO(kasper): Consider optimizing this through
    // the use of another map keyed by the gid.
    jobs_.do --values: | job/ContainerJob |
      if job.gid == gid: return job
    return null

  create --name/string --id/uuid.Uuid --description/Map -> ContainerJob?
      --reader/Reader?=null:
    if reader:
      writer/containers.ContainerImageWriter := ?
      if reader is SizedReader:
        size := (reader as SizedReader).size
        logger_.info "image download" --tags={"id": id, "size": size}
        writer = containers.ContainerImageWriter size
        while data := reader.read: writer.write data
      else:
        logger_.warn "image download with unknown size" --tags={"id": id}
        data := utils.read-all reader
        writer = containers.ContainerImageWriter data.size
        writer.write data
      image := writer.commit
      logger_.info "image downloaded" --tags={"id": image}
      if image != id: throw "invalid state"
      images_.add id
    else if not images_.contains id:
      return null
    return ContainerJob
        --name=name
        --id=id
        --description=description
        --pin-trigger-manager=pin-trigger-manager_
        --logger=logger_

  install job/ContainerJob -> none:
    if job.trigger-install_:
      job.trigger (encode-trigger-reason_ --install)
    add_ job --message="install"

  uninstall job/ContainerJob -> none:
    remove_ job --message="uninstall"
    id := job.id
    // TODO(kasper): We could consider using reference counting
    // here instead of running through the jobs.
    preserve := images-bundled_.contains id
        or jobs_.any --values: it.id == id
    if preserve: return
    containers.uninstall job.id
    images_.remove id
    logger_.info "image uninstalled" --tags={"id": id}

  update job/ContainerJob description/Map -> none:
    scheduler_.remove-job job
    job.update description
    pin-trigger-manager_.update-job job
    // After updating the description of an app, we consider it
    // as newly installed. Rearm it if it has an install trigger.
    if job.trigger-install_:
      job.trigger (encode-trigger-reason_ --install)
    logger_.info "update" --tags=job.tags
    scheduler_.add-job job

  add_ job/ContainerJob --message/string -> none:
    jobs_[job.name] = job
    scheduler_.add-job job
    logger_.info message --tags=job.tags

  remove_ job/ContainerJob --message/string -> none:
    jobs_.remove job.name
    scheduler_.remove-job job
    logger_.info message --tags=job.tags

encode-trigger_reason_ -> int
    --boot/bool=false
    --install/bool=false
    --interval/bool=false
    --restart/bool=false
    --critical/bool=false
    --pin/int?=null
    --touch/int?=null:
  // These constants must be kept in sync with the ones in the
  // Artemis package.
  if boot: return 0
  if install: return 1
  if interval: return 2
  if restart: return 3
  if critical: return 4
  if pin: return (pin << 8) | 10
  if touch: return (touch << 8) | 11
  throw "invalid trigger"

class ContainerJob extends Job:
  // The key of the ID in the $description.
  static KEY-ID ::= "id"

  pin-trigger-manager_/PinTriggerManager
  logger_/log.Logger

  id/uuid.Uuid
  description_/Map := ?
  running_/containers.Container? := null
  runlevel_/int := Job.RUNLEVEL-NORMAL

  is-background_/bool := false
  trigger-boot_/bool := false
  trigger-install_/bool := false
  trigger-interval_/Duration? := null
  trigger-gpio-levels_/Map? := null
  trigger-gpio-touch_/Set? := null

  is-triggered_/bool := false
  // The reason for why this job was triggered.
  last-trigger-reason_/int? := null

  constructor
      --name/string
      --.id
      --description/Map
      --pin-trigger-manager/PinTriggerManager
      --logger/log.Logger:
    description_ = description
    pin-trigger-manager_ = pin-trigger-manager
    logger_ = logger.with-name name
    super name
    update description

  stringify -> string:
    return "container:$name"

  is-running -> bool:
    return running_ != null

  is-background -> bool:
    return is-background_

  is-critical -> bool:
    return runlevel_ <= Job.RUNLEVEL-CRITICAL

  gid -> int?:
    running := running_
    return running and running.gid

  runlevel -> int:
    return runlevel_

  description -> Map:
    return description_

  tags -> Map:
    return { "name": name, "id": id }

  schedule now/JobTime last/JobTime? -> JobTime?:
    // TODO(kasper): Should the delayed restart take
    // precedence over all other triggers? Also, we
    // should probably think about how we want to access
    // the scheduler state here.
    if delayed-until := scheduler-delayed-until_:
      if delayed-until > now: return delayed-until
      trigger (encode-trigger-reason_ --restart)
    else if is-critical:
      // TODO(kasper): Find a way to reboot the device if
      // a critical container keeps restarting.
      trigger (encode-trigger-reason_ --critical)
    else if trigger-interval_:
      result := last ? last + trigger-interval_ : now
      if result > now: return result
      trigger (encode-trigger-reason_ --interval)

    if is-triggered_: return now
    // TODO(kasper): Don't run at all. Maybe that isn't
    // a great default when you have no triggers?
    return null

  /**
  Triggers this job, making it run as soon as possible.
  */
  trigger reason/int:
    if is-running or is-triggered_: return
    is-triggered_ = true
    last-trigger-reason_ = reason

  schedule-tune last/JobTime -> JobTime:
    // If running the container took a long time, we tune the
    // schedule and postpone the next run by making it start
    // at the beginning of the next period instead of now.
    return Job.schedule-tune-periodic last trigger-interval_

  start -> none:
    if running_: return
    arguments := description_.get "arguments"
    logger_.debug "starting" --tags={
      "reason": last-trigger-reason_,
      "arguments": arguments
    }
    running_ = containers.start id arguments

    scheduler_.on-job-started this
    running_.on-stopped::
      running_ = null
      is-triggered_ = false
      pin-trigger-manager_.rearm-job this
      scheduler_.on-job-stopped this

  stop -> none:
    if not running_: return
    running_.stop  // Waits until the container has stopped.

  restart --wakeup-us/int? -> none:
    wakeup := JobTime.now
    if wakeup-us: wakeup += Duration --us=(wakeup-us - Time.monotonic-us)
    scheduler_.delay-job this --until=wakeup
    // If restart was called from the container being restarted,
    // we're in the middle of doing an RPC call here. Stopping
    // the container will cause the RPC processing task doing
    // the call to get canceled, so this better be the very last
    // thing we do.
    stop

  update description/Map -> none:
    assert: not is-running
    description_ = description
    is-background_ = description.contains "background"

    runlevel_ = description.get "runlevel" --if-absent=: Job.RUNLEVEL-NORMAL

    // TODO(florian): Remove updates of the runlevel_.
    // Update runlevel.
    if description.contains "critical":
      runlevel_ = Job.RUNLEVEL-CRITICAL

    // Reset triggers.
    trigger-boot_ = false
    trigger-install_ = false
    trigger-interval_ = null
    trigger-gpio-levels_ = null
    trigger-gpio-touch_ = null

    // Update triggers unless we're a critical container.
    if is-critical: return
    description_.get "triggers" --if-present=: | triggers/Map |
      triggers.do: | name/string value |
        if name == "boot": trigger-boot_ = true
        if name == "install": trigger-install_ = true
        if name == "interval": trigger-interval_ = (Duration --s=value)
        if name.starts-with "gpio-high:":
          if not trigger-gpio-levels_: trigger-gpio-levels_ = {:}
          trigger-gpio-levels_[value] = 1
        if name.starts-with "gpio-low:":
          if not trigger-gpio-levels_: trigger-gpio-levels_ = {:}
          trigger-gpio-levels_[value] = 0
        if name.starts-with "gpio-touch:":
          if not trigger-gpio-touch_: trigger-gpio-touch_ = {}
          trigger-gpio-touch_.add value

  has-gpio-pin-triggers -> bool:
    return trigger-gpio-levels_ != null

  has-touch-triggers -> bool:
    return trigger-gpio-touch_ != null

  has-pin-triggers -> bool:
    return has-gpio-pin-triggers or trigger-gpio-touch_ != null

  has-pin-trigger pin/int --level/int -> bool:
    return has-gpio-pin-triggers and (trigger-gpio-levels_.get pin) == level

  has-touch-trigger pin/int -> bool:
    return has-touch-triggers and trigger-gpio-touch_.contains pin
