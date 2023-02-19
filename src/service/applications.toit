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

class Application extends Job:
  id/string
  container_/uuid.Uuid? := null

  constructor name/string .id:
    super name

  stringify -> string:
    return "application:$name"

  tags -> Map:
    return { "name": name, "id": id }

  is_complete -> bool:
    return container_ != null

  schedule now/JobTime -> JobTime?:
    if not container_: return null
    if last_run: return null  // Run once (at install time).
    return now

  run -> none:
    containers.start container_

  complete_ reader/SizedReader -> none:
    writer ::= containers.ContainerImageWriter reader.size
    while data := reader.read: writer.write data
    container_ = writer.commit

  delete_ -> none:
    container ::= container_
    if container: containers.uninstall container
    container_ = null
