// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import mqtt
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
    applications_.do: | _ application/Application |
      if not application.is_complete: return true
    return false

  get id/string -> Application?:
    return applications_.get id

  install application/Application:
    applications_[application.id] = application
    scheduler_.add_job application
    logger_.info "install" --tags=application.tags

  complete application/Application reader/SizedReader:
    if application.is_complete: return
    application.complete reader
    scheduler_.on_job_ready application
    logger_.info "complete" --tags=application.tags

  uninstall application/Application:
    application.delete
    scheduler_.remove_job application
    logger_.info "uninstall" --tags=application.tags

  synchronize client/mqtt.FullClient -> none:
    pruned/List? := null
    applications_.do: | _ application/Application |
      application.synchronize client
      if application.is_prunable:
        pruned = pruned or []
        pruned.add application
    if not pruned: return
    pruned.do: applications_.remove it.id

class Application extends Job:
  static STATE_CREATED_                ::= 0 << 1 | 0
  static STATE_CREATED_SUBSCRIBED_     ::= 1 << 1 | 1
  static STATE_COMPLETED_              ::= 2 << 1 | 1
  static STATE_COMPLETED_UNSUBSCRIBED_ ::= 3 << 1 | 0
  static STATE_DELETED_                ::= 4 << 1 | 1
  static STATE_DELETED_UNSUBSCRIBED_   ::= 5 << 1 | 0

  id/string
  container_/uuid.Uuid? := null
  state_/int := STATE_CREATED_

  constructor name/string .id:
    super name

  stringify -> string:
    return "application:$name"

  tags -> Map:
    return { "name": name, "id": id }

  is_complete -> bool:
    state ::= state_
    return state == STATE_COMPLETED_ or state == STATE_COMPLETED_UNSUBSCRIBED_

  is_prunable -> bool:
    return state_ == STATE_DELETED_UNSUBSCRIBED_

  schedule now/JobTime -> JobTime?:
    if not container_: return null
    if last_run: return null  // Run once (at install time).
    return now

  run -> none:
    containers.start container_

  synchronize client/mqtt.FullClient -> none:
    if state_ == STATE_CREATED_:
      client.subscribe topic_
      state_ = STATE_CREATED_SUBSCRIBED_
    else if state_ == STATE_COMPLETED_:
      client.unsubscribe topic_
      state_ = STATE_COMPLETED_UNSUBSCRIBED_
    else if state_ == STATE_DELETED_:
      client.unsubscribe topic_
      state_ = STATE_DELETED_UNSUBSCRIBED_

  complete payload/SizedReader -> none:
    assert: state_ == STATE_CREATED_SUBSCRIBED_
    writer ::= containers.ContainerImageWriter payload.size
    while data := payload.read: writer.write data
    container_ = writer.commit
    state_ = STATE_COMPLETED_

  delete -> none:
    container ::= container_
    if container: containers.uninstall container
    container_ = null
    // Update the state. We always end up being deleted,
    // but we take care
    state_ = (state_ & 1 == 1)
        ? STATE_DELETED_
        : STATE_DELETED_UNSUBSCRIBED_

  topic_ -> string:
    return "toit/apps/$id/image$BITS_PER_WORD"
