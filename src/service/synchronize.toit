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
import ..shared.differ show Modification

CLIENT_ID ::= "toit/artemis-service-$(random 0x3fff_ffff)"

revision/int? := null
config/Map ::= {:}
max_offline/Duration? := null

// Index in return value from `process_stats`.
BYTES_ALLOCATED ::= 4

class SynchronizeJob extends Job:
  logger_/log.Logger
  device/ArtemisDevice
  applications_/ApplicationManager
  actions_/monitor.Channel ::= monitor.Channel 16  // TODO(kasper): Maybe this should be unbounded?

  constructor logger/log.Logger .device .applications_:
    logger_ = logger.with_name "synchronize"
    super "synchronize"

  schedule now/JobTime -> JobTime?:
    if not last_run or not max_offline: return now
    return last_run + max_offline

  run -> none:
    stats := List BYTES_ALLOCATED + 1  // Use this to collect stats to avoid allocation.
    allocated := (process_stats stats)[BYTES_ALLOCATED]
    logger_.info "connecting to broker" --tags={"device": device.name}

    run_client_: | client/mqtt.FullClient |
      while true:
        applications_.synchronize client
        actions/ActionBundle? := actions_.receive
        if actions: actions.commit config
        // If there is more work to do, we take another spin in the loop.
        if actions_.size > 0 or applications_.any_incomplete: continue

        new_allocated := (process_stats stats)[BYTES_ALLOCATED]
        delta := new_allocated - allocated
        logger_.info "synchronized" --tags={"allocated": delta}
        allocated = new_allocated
        if max_offline:
          logger_.info "going offline" --tags={"duration": max_offline}
          return

  handle_nop_ -> none:
    actions_.send null

  handle_new_config_ new_config/Map -> none:
    modification/Modification? := Modification.compute
        --from=config
        --to=new_config
    if not modification: return

    actions := ActionBundle "apps"
    modification.on_map "apps"
        --added   =: | key value | actions.add (ActionApplicationInstall applications_ key value)
        --removed =: | key value | actions.add (ActionApplicationUninstall applications_ key value)
        --updated =: | key from to | actions.add (ActionApplicationUpdate applications_ key to from)

    modification.on_value "max-offline"
        --added   =: | value | max_offline = Duration --s=value
        --removed =: | value | max_offline = null

    actions_.send actions

  handle_new_image_ topic/string packet/mqtt.PublishPacket -> none:
    // TODO(kasper): This is a bit hacky.
    path := topic.split "/"
    id := path[2]
    application/Application? := applications_.get id
    if not application: return
    applications_.complete application packet.payload_stream
    actions_.send null

  run_client_ [block]:
    network ::= net.open
    transport ::= create_transport network
    client/mqtt.FullClient? := mqtt.FullClient --transport=transport

    // Since we are using `retain` for important data, we simply connect
    // with the clean-session flag. The broker does not need to save
    // QoS packets that aren't retained.
    last_will ::= mqtt.LastWill device.topic_presence "disappeared".to_byte_array
        --retain
        --qos=0
    options ::= mqtt.SessionOptions
        --client_id=CLIENT_ID
        --clean_session
        --last_will=last_will

    client.connect --options=options
    disconnected := monitor.Latch

    handle_task/Task? := ?
    handle_task = task::
      catch --trace:
        try:
          subscribed_to_config := false
          new_config/Map? := null
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
                    handle_new_config_ new_config
                else:
                  handle_nop_
              else if topic == device.topic_config:
                new_config = ubjson.decode publish.payload
                if revision == new_config["revision"]:
                  handle_new_config_ new_config
              else if topic.starts_with "toit/apps/":
                handle_new_image_ topic publish
        finally:
          critical_do:
            disconnected.set true
            client.close --force
            network.close
          client = null
          handle_task = null

    try:
      // Wait for the client to run.
      client.when_running: null
      client.publish device.topic_presence "online".to_byte_array --retain
      client.subscribe device.topic_revision
      block.call client
    finally:
      try:
        if client: client.publish device.topic_presence "offline".to_byte_array --retain
        if client: client.close
        with_timeout --ms=3_000: disconnected.get
      finally:
        if handle_task: handle_task.cancel
