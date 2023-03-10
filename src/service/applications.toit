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

  images_ ::= {}          // Set<uuid.Uuid>
  images_bundled_ ::= {}  // Set<uuid.Uuid>
  applications_ ::= {:}   // Map<string, Application>

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
      catch: id = uuid.parse (description.get Application.KEY_ID)
      if not id: continue.do
      application := create --name=name --id=id --description=description
      add_ application --message="load"

  any_incomplete -> bool:
    return first_incomplete != null

  first_incomplete -> Application?:
    applications_.do: | _ application/Application |
      if not application.is_complete: return application
    return null

  get --name/string -> Application?:
    return applications_.get name

  create --name/string --id/uuid.Uuid --description/Map -> Application:
    application := Application --name=name --id=id --description=description
    if images_.contains id: application.is_complete_ = true
    return application

  install application/Application -> none:
    add_ application --message="install"

  complete application/Application reader/SizedReader -> none:
    if application.is_complete: return
    id := application.id
    writer ::= containers.ContainerImageWriter reader.size
    while data := reader.read: writer.write data
    image := writer.commit
    logger_.info "installed image" --tags={"id": image}
    if image != id: throw "invalid state"
    application.is_complete_ = true
    images_.add id
    logger_.info "complete" --tags=application.tags
    scheduler_.on_job_ready application

  uninstall application/Application -> none:
    applications_.remove application.name
    scheduler_.remove_job application
    logger_.info "uninstall" --tags=application.tags
    if not application.is_complete: return
    id := application.id
    // TODO(kasper): We could consider using reference counting
    // here instead of running through the applications.
    preserve := images_bundled_.contains id
        or applications_.any --values: it.id == id
    application.is_complete_ = false
    if preserve: return
    containers.uninstall application.id
    images_.remove id
    logger_.info "uninstalled image" --tags={"id": id}

  update application/Application description/Map -> none:
    if application.is_complete: scheduler_.remove_job application
    application.update description
    if application.is_complete: scheduler_.add_job application
    logger_.info "update" --tags=application.tags

  add_ application/Application --message/string -> none:
    applications_[application.name] = application
    scheduler_.add_job application
    logger_.info message --tags=application.tags

class Application extends Job:
  // The key of the ID in the $description.
  static KEY_ID ::= "id"

  id/uuid.Uuid
  description_/Map := ?
  container_/containers.Container? := null

  // The $ApplicationManager is responsible for marking
  // applications as complete and it manipulates this
  // field directly.
  is_complete_/bool := false

  constructor --name/string --.id --description/Map:
    description_ = description
    super name

  stringify -> string:
    return "application:$name"

  is_complete -> bool:
    return is_complete_

  is_running -> bool:
    return container_ != null

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
    if container_: return
    arguments := description_.get "arguments"
    container_ = containers.start id arguments
    scheduler_.on_job_started this
    container_.on_stopped::
      container_ = null
      scheduler_.on_job_stopped this

  stop -> none:
    if not container_: return
    container_.stop

  update description/Map -> none:
    assert: not is_running
    description_ = description
