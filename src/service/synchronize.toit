// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import log
import net
import monitor
import mqtt
import mqtt.packets as mqtt
import uuid

import system.containers

import .actions
import .applications
import .jobs

import ..shared.connect

CLIENT_ID ::= "toit/artemis-service-$(random 0x3fff_ffff)"

revision/int? := null
config/Map ::= {:}
max_offline/Duration? := null

client/mqtt.FullClient? := null
logger/log.Logger ::= log.default.with_name "artemis"

// Index in return value from `process_stats`.
BYTES_ALLOCATED ::= 4

class SynchronizeJob extends Job:
  device/ArtemisDevice
  applications_/ApplicationManager
  actions_/monitor.Channel ::= monitor.Channel 16  // TODO(kasper): Maybe this should be unbounded?

  constructor .device .applications_:

  schedule now/JobTime -> JobTime?:
    if not last_run or not max_offline: return now
    return last_run + max_offline

  run -> none:
    synchronize_

  synchronize_ -> none:
    stats := List BYTES_ALLOCATED + 1  // Use this to collect stats to avoid allocation.
    allocated := (process_stats stats)[BYTES_ALLOCATED]
    logger.info "connecting to broker" --tags={"device": device.name}

    disconnect ::= run_client this
    try:
      while true:
        applications_.synchronize client
        if process_actions_: continue

        new_allocated := (process_stats stats)[BYTES_ALLOCATED]
        delta := new_allocated - allocated
        logger.info "synchronized" --tags={"allocated": delta}
        allocated = new_allocated
        if max_offline:
          logger.info "going offline" --tags={"duration": max_offline}
          return
    finally:
      disconnect.call

  process_actions_ -> bool:
    actions/List? := actions_.receive

    // TODO(kasper): Not all actions will work on the 'apps' subsection,
    // so this needs to be generalized.
    if actions: config["apps"] = Action.apply actions (config.get "apps")

    // If there are any incomplete apps left, we still have
    // work to do, so we return true. If all apps have been
    // completed, we're done.
    return actions_.size > 0 or applications_.any_incomplete

  handle_nop -> none:
    actions_.send null

  handle_new_config new_config/Map -> none:
    actions := []
    existing := config.get "apps" --if_absent=: {:}
    apps := new_config.get "apps" --if_absent=: {:}
    apps.do: | name new |
      old := existing.get name
      if old != new:
        // New or updated app.
        if old:
          actions.add (ActionApplicationUpdate applications_ name new old)
        else:
          actions.add (ActionApplicationInstall applications_ name new)
    existing.do: | name old |
      if apps.get name: continue.do
      actions.add (ActionApplicationUninstall applications_ name old)

    // TODO(kasper): Should this just stay in config?
    if new_config.contains "max-offline":
      max_offline = Duration --s=new_config["max-offline"]
    else:
      max_offline = null

    actions_.send actions

  handle_new_image topic/string packet/mqtt.PublishPacket -> none:
    // TODO(kasper): This is a bit hacky.
    path := topic.split "/"
    id := path[2]
    application/Application? := applications_.get id
    if not application or application.is_complete: return
    application.complete packet.payload_stream
    logger.info "app install: received image" --tags={
        "name": application.name,
        "id": application.id,
    }
    actions_.send null

// TODO(kasper): Turn this into a method on SynchronizeJob.
run_client job/SynchronizeJob -> Lambda:
  device ::= job.device
  network := net.open
  transport := create_transport network
  client = mqtt.FullClient --transport=transport

  // Since we are using `retain` for important data, we simply connect
  // with the clean-session flag. The broker does not need to save
  // QoS packets that aren't retained.
  options := mqtt.SessionOptions
      --client_id=CLIENT_ID
      --clean_session
      --last_will=(mqtt.LastWill --retain device.topic_presence "disappeared".to_byte_array --qos=0)

  client.connect --options=options

  disconnected := monitor.Latch

  // Add the topics we care about.
  subscribed_to_config := false
  new_config/Map? := null

  handle_task/Task? := ?
  handle_task = task::
    catch --trace:
      try:
        client.handle: | packet/mqtt.Packet |
          if packet is mqtt.PublishPacket:
            publish := packet as mqtt.PublishPacket
            topic := publish.topic
            if topic == device.topic_revision:
              new_revision := ubjson.decode publish.payload
              if new_revision != revision:
                revision = new_revision
                if not subscribed_to_config:
                  subscribed_to_config = true
                  client.subscribe device.topic_config
                if new_config and revision == new_config["revision"]:
                  job.handle_new_config new_config
              else:
                job.handle_nop
            else if topic == device.topic_config:
              new_config = ubjson.decode publish.payload
              if revision == new_config["revision"]:
                job.handle_new_config new_config
            else if topic.starts_with "toit/apps/":
              job.handle_new_image topic publish
      finally:
        critical_do:
          disconnected.set true
          client.close --force
          network.close
        client = null
        handle_task = null

  // Wait for the client to run.
  client.when_running: null
  client.publish device.topic_presence "online".to_byte_array --retain
  client.subscribe device.topic_revision

  disconnect_lambda := ::
    try:
      if client: client.publish device.topic_presence "offline".to_byte_array --retain
      if client: client.close
      with_timeout --ms=3_000: disconnected.get
    finally:
      if handle_task: handle_task.cancel
  return disconnect_lambda
