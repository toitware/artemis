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
      id_string/string? := description.get Application.KEY_ID
      application := build name id_string description
      add_ application --message="load"

  any_incomplete -> bool:
    return first_incomplete != null

  first_incomplete -> Application?:
    applications_.do: | _ application/Application |
      if not application.is_complete: return application
    return null

  get --name/string -> Application?:
    return applications_.get name

  // TODO(kasper): Rename this to something better.
  build name/string id_string/string description/Map -> Application:
    id/uuid.Uuid? := null
    catch: id = id_string and uuid.parse id_string
    application/Application := ?
    if id and images_.contains id:
      return Application.completed name --id=id --description=description
    else:
      return Application name --id=id_string --description=description

  install application/Application -> none:
    add_ application --message="install"

  complete application/Application reader/SizedReader -> none:
    if application.is_complete: return
    application.complete_ reader
    // TODO(kasper): Clean this up. It is super confusing
    // that the id is a string here.
    id/string := application.id
    images_.add id
    logger_.info "container image installed" --tags={"id": id}
    logger_.info "complete" --tags=application.tags
    scheduler_.on_job_ready application

  uninstall application/Application -> none:
    applications_.remove application.name
    scheduler_.remove_job application
    logger_.info "uninstall" --tags=application.tags
    if not application.is_complete: return
    // TODO(kasper): Clean this up. It is super confusing
    // that the id is a string here.
    id/string := application.id
    preserve := images_bundled_.contains id
        or applications_.any --values: it.id == id
    container_image := application.container_image_
    application.mark_incomplete_
    if preserve: return
    containers.uninstall container_image
    images_.remove id
    logger_.info "container image uninstalled" --tags={"id": id}

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

  id/string
  description_/Map := ?
  container_image_/uuid.Uuid? := null
  container_/containers.Container? := null

  constructor name/string --.id --description/Map:
    description_ = description
    super name

  constructor.completed name/string --id/uuid.Uuid --description/Map:
    this.id = id.stringify
    description_ = description
    container_image_ = id
    super name

  stringify -> string:
    return "application:$name"

  is_running -> bool:
    return container_ != null

  description -> Map:
    return description_

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
    arguments := description_.get "arguments"
    container_ = containers.start container_image_ arguments
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

  complete_ reader/SizedReader -> none:
    writer ::= containers.ContainerImageWriter reader.size
    while data := reader.read: writer.write data
    container_image_ = writer.commit
    // TODO(kasper): Clean this up. We don't need two ids in the
    // application that must be the same.
    if container_image_.stringify != id: throw "invalid state"

  mark_incomplete_ -> none:
    container_image_ = null