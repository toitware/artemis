// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import reader show Reader SizedReader
import uuid

import system.containers
import supabase.utils

import .jobs
import .scheduler

class ContainerManager:
  logger_/log.Logger
  scheduler_/Scheduler

  jobs_ ::= {:}           // Map<string, ContainerJob>
  images_ ::= {}          // Set<uuid.Uuid>
  images_bundled_ ::= {}  // Set<uuid.Uuid>

  constructor logger/log.Logger .scheduler_:
    logger_ = logger.with_name "containers"
    containers.images.do: | image/containers.ContainerImage |
      images_.add image.id
      // TODO(kasper): It feels like a bit of a hack to determine
      // if an installed container image is bundled based on
      // whether or not it has a name.
      is_bundled := image.name != null
      if is_bundled: images_bundled_.add image.id

  load state/Map -> none:
    apps := state.get "apps" --if_absent=: return
    apps.do: | name description |
      id/uuid.Uuid? := null
      catch: id = uuid.parse (description.get ContainerJob.KEY_ID)
      if not id: continue.do
      job := create --name=name --id=id --description=description
      // TODO(kasper): We should be able to find all container
      // images used by the current state in flash, so it isn't
      // very clear how we should handle it if we cannot. Should
      // we drop such an app from the current state? Seems like
      // the right thing to do.
      if job: add_ job --message="load"

  get --name/string -> ContainerJob?:
    return jobs_.get name

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
        data := utils.read_all reader
        writer = containers.ContainerImageWriter data.size
        writer.write data
      image := writer.commit
      logger_.info "image downloaded" --tags={"id": image}
      if image != id: throw "invalid state"
      images_.add id
    else if not images_.contains id:
      return null
    return ContainerJob --name=name --id=id --description=description

  install job/ContainerJob -> none:
    job.has_run_after_install_ = false
    add_ job --message="install"

  uninstall job/ContainerJob -> none:
    jobs_.remove job.name
    scheduler_.remove_job job
    logger_.info "uninstall" --tags=job.tags
    id := job.id
    // TODO(kasper): We could consider using reference counting
    // here instead of running through the jobs.
    preserve := images_bundled_.contains id
        or jobs_.any --values: it.id == id
    if preserve: return
    containers.uninstall job.id
    images_.remove id
    logger_.info "image uninstalled" --tags={"id": id}

  update job/ContainerJob description/Map -> none:
    scheduler_.remove_job job
    job.update description
    // After updating the description of an app, we
    // mark it as being newly installed for the purposes
    // of scheduling. This means that it will start
    // again if it has an install trigger.
    job.has_run_after_install_ = false
    logger_.info "update" --tags=job.tags
    scheduler_.add_job job

  add_ job/ContainerJob --message/string -> none:
    jobs_[job.name] = job
    scheduler_.add_job job
    logger_.info message --tags=job.tags

class ContainerJob extends Job:
  // The key of the ID in the $description.
  static KEY_ID ::= "id"

  id/uuid.Uuid
  description_/Map := ?
  running_/containers.Container? := null
  runlevel_/int := Job.RUNLEVEL_NORMAL

  is_background_/bool := false
  trigger_boot_/bool := false
  trigger_install_/bool := false
  trigger_interval_/Duration? := null
  triggers_gpio_/Map? := null

  // The $ContainerManager is responsible for scheduling
  // newly installed containers, so it manipulates this
  // field directly.
  has_run_after_install_/bool := true

  constructor --name/string --.id --description/Map:
    description_ = description
    super name
    update description

  stringify -> string:
    return "container:$name"

  is_running -> bool:
    return running_ != null

  is_background -> bool:
    return is_background_

  runlevel -> int:
    return runlevel_

  description -> Map:
    return description_

  tags -> Map:
    // TODO(florian): do we want to add the description here?
    return { "name": name, "id": id }

  schedule now/JobTime last/JobTime? -> JobTime?:
    if runlevel_ <= Job.RUNLEVEL_CRITICAL:
      // TODO(kasper): Find a way to reboot the device if
      // a critical container keeps restarting.
      return now
    else if trigger_boot_ and not has_run_after_boot:
      return now
    else if trigger_install_ and not has_run_after_install_:
      return now
    else if trigger_interval_:
      return last ? last + trigger_interval_ : now
    else:
      // TODO(kasper): Don't run at all. Maybe that isn't
      // a great default when you have no triggers?
      return null

  schedule_tune last/JobTime -> JobTime:
    // If running the container took a long time, we tune the
    // schedule and postpone the next run by making it start
    // at the beginning of the next period instead of now.
    return Job.schedule_tune_periodic last trigger_interval_

  start now/JobTime -> none:
    if running_: return
    arguments := description_.get "arguments"
    has_run_after_install_ = true
    running_ = containers.start id arguments
    scheduler_.on_job_started this
    running_.on_stopped::
      running_ = null
      scheduler_.on_job_stopped this

  stop -> none:
    if not running_: return
    running_.stop

  update description/Map -> none:
    assert: not is_running
    description_ = description
    is_background_ = description.contains "background"

    // Update runlevel.
    if name.starts_with "cellular":
      // TODO(kasper): This is a hack. We should replace this
      // something more general.
      runlevel_ = Job.RUNLEVEL_SAFE
    else if description.contains "critical":
      runlevel_ = Job.RUNLEVEL_CRITICAL
    else:
      runlevel_ = Job.RUNLEVEL_NORMAL

    // Update triggers.
    trigger_boot_ = false
    trigger_install_ = false
    trigger_interval_ = null
    triggers_gpio_ = null
    if runlevel_ <= Job.RUNLEVEL_CRITICAL: return

    description_.get "triggers" --if_present=: | triggers/Map |
      triggers.do: | name/string value |
        if name == "boot": trigger_boot_ = true
        if name == "install": trigger_install_ = true
        if name == "interval": trigger_interval_ = (Duration --s=value)
        if name.starts_with "gpio-high:":
          if not triggers_gpio_: triggers_gpio_ = {:}
          triggers_gpio_[value] = 1
        if name.starts_with "gpio-low:":
          if not triggers_gpio_: triggers_gpio_ = {:}
          triggers_gpio_[value] = 0
