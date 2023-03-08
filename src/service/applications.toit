// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import reader show SizedReader
import uuid

import system.containers

import .jobs
import .scheduler

class ApplicationManager:
  logger_/log.Logger
  scheduler_/Scheduler
  applications_ := {:}  // Map<string, Application>

  constructor logger/log.Logger .scheduler_:
    logger_ = logger.with_name "apps"

  any_incomplete -> bool:
    return first_incomplete != null

  first_incomplete -> Application?:
    applications_.do: | _ application/Application |
      if not application.is_complete: return application
    return null

  get id/string -> Application?:
    return applications_.get id

  install application/Application:
    applications_[application.id] = application
    scheduler_.add_job application
    logger_.info "install" --tags=application.tags

  complete application/Application reader/SizedReader:
    if application.is_complete: return
    application.complete_ reader
    scheduler_.on_job_ready application
    logger_.info "complete" --tags=application.tags

  uninstall application/Application:
    applications_.remove application.id
    application.delete_
    scheduler_.remove_job application
    logger_.info "uninstall" --tags=application.tags

  update application/Application:
    if not application.is_complete: return
    old_application := applications_.get application.id
    scheduler_.remove_job old_application
    applications_[application.id] = application
    scheduler_.add_job application
    logger_.info "update" --tags=application.tags

class Application extends Job:
  // The key of the ID in the $description.
  static KEY_ID ::= "id"

  id/string
  description/Map
  container_image_/uuid.Uuid? := null
  container_/containers.Container? := null

  constructor name/string --.id --.description:
    super name

  constructor.completed name/string --id/uuid.Uuid --.description:
    this.id = id.stringify
    container_image_ = id
    super name

  stringify -> string:
    return "application:$name"

  is_running -> bool:
    return container_ != null

  tags -> Map:
    // TODO(florian): do we want to add the description here?
    return { "name": name, "id": id }

  is_complete -> bool:
    return container_image_ != null

  schedule now/JobTime last/JobTime? -> JobTime?:
    if not container_image_: return null
    if has_run_after_boot: return null  // Run once at boot.
    return now

  start now/JobTime -> none:
    if container_: return
    arguments := description.get "arguments"
    container_ = containers.start container_image_ arguments
    scheduler_.on_job_started this
    container_.on_stopped::
      container_ = null
      scheduler_.on_job_stopped this

  stop -> none:
    if not container_: return
    container_.stop

  complete_ reader/SizedReader -> none:
    writer ::= containers.ContainerImageWriter reader.size
    while data := reader.read: writer.write data
    container_image_ = writer.commit
    // TODO(kasper): Clean this up. We don't need two ids in the
    // application that must be the same.
    if container_image_.stringify != id: throw "invalid state"

  delete_ -> none:
    container_image ::= container_image_
    if container_image: containers.uninstall container_image
    container_image_ = null

  with --description/Map:
    result := Application name --id=id --description=description
    result.container_image_ = container_image_
    return result
