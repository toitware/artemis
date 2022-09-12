// Copyright (C) 2022 Toitware ApS. All rights reserved.

import uuid
import system.containers
import mqtt
import reader show SizedReader

import .scheduler show Job SchedulerTime Scheduler

class ApplicationManager:
  static instance ::= ApplicationManager
  applications_ := {:}  // Map<string, Application>

  complete -> bool:
    applications_.do: | id/string application/Application |
      if application.container == null: return false
    return true

  lookup id/string -> Application?:
    return applications_.get id

  install application/Application:
    applications_[application.id] = application
    Scheduler.instance.add_job application

  uninstall application/Application:
    container := application.container
    if container: containers.uninstall container
    Scheduler.instance.remove_job application
    applications_.remove application.id

  subscribe client/mqtt.FullClient -> none:
    applications_.do: | id/string application/Application |
      container := application.container
      if container: continue.do
      application.subscribe client

class Application extends Job:
  name/string
  id/string
  container_/uuid.Uuid? := null
  subscribed_ := false
  constructor .name .id:

  container -> uuid.Uuid?:
    return container_

  schedule now/SchedulerTime -> SchedulerTime?:
    if not container: return null
    if last_run: return null  // Run once (at install time).
    return now

  run -> none:
    containers.start container

  subscribe client/mqtt.FullClient:
    if subscribed_: return
    client.subscribe topic_
    subscribed_ = true

  fetch client/mqtt.FullClient payload/SizedReader:
    subscribed_ = false
    // TODO(kasper): We need to unsubscribe after we're done fetching. Maybe
    // we can let the application manager handle that for us?
    // client.unsubscribe topic_
    writer := containers.ContainerImageWriter payload.size
    while data := payload.read: writer.write data
    container_ = writer.commit

  topic_ -> string:
    return "toit/apps/$id/image$BITS_PER_WORD"
