// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import reader show SizedReader
import uuid

import system.containers

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
      add_ job --message="load"

  any_incomplete -> bool:
    return first_incomplete != null

  first_incomplete -> ContainerJob?:
    jobs_.do: | _ job/ContainerJob |
      if not job.is_complete: return job
    return null

  get --name/string -> ContainerJob?:
    return jobs_.get name

  create --name/string --id/uuid.Uuid --description/Map -> ContainerJob:
    job := ContainerJob --name=name --id=id --description=description
    if images_.contains id: job.is_complete_ = true
    return job

  install job/ContainerJob -> none:
    add_ job --message="install"

  complete job/ContainerJob reader/SizedReader -> none:
    if job.is_complete: return
    id := job.id
    writer ::= containers.ContainerImageWriter reader.size
    while data := reader.read: writer.write data
    image := writer.commit
    logger_.info "installed image" --tags={"id": image}
    if image != id: throw "invalid state"
    job.is_complete_ = true
    images_.add id
    logger_.info "complete" --tags=job.tags
    scheduler_.on_job_ready job

  uninstall job/ContainerJob -> none:
    jobs_.remove job.name
    scheduler_.remove_job job
    logger_.info "uninstall" --tags=job.tags
    if not job.is_complete: return
    id := job.id
    // TODO(kasper): We could consider using reference counting
    // here instead of running through the jobs.
    preserve := images_bundled_.contains id
        or jobs_.any --values: it.id == id
    job.is_complete_ = false
    if preserve: return
    containers.uninstall job.id
    images_.remove id
    logger_.info "uninstalled image" --tags={"id": id}

  update job/ContainerJob description/Map -> none:
    if job.is_complete: scheduler_.remove_job job
    job.update description
    if job.is_complete: scheduler_.add_job job
    logger_.info "update" --tags=job.tags

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

  // The $ContainerManager is responsible for marking
  // container jobs as complete and it manipulates this
  // field directly.
  is_complete_/bool := false

  constructor --name/string --.id --description/Map:
    description_ = description
    super name

  stringify -> string:
    return "container:$name"

  is_complete -> bool:
    return is_complete_

  is_running -> bool:
    return running_ != null

  description -> Map:
    return description_

  tags -> Map:
    // TODO(florian): do we want to add the description here?
    return { "name": name, "id": id }

  schedule now/JobTime last/JobTime? -> JobTime?:
    if not is_complete_: return null
    if has_run_after_boot: return null  // Run once at boot.
    return now

  start now/JobTime -> none:
    assert: is_complete
    if running_: return
    arguments := description_.get "arguments"
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