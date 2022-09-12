// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import mqtt
import mqtt.packets as mqtt
import monitor
import encoding.ubjson

import system.containers
import log

import .scheduler show Job SchedulerTime
import ..shared.connect

CLIENT_ID ::= "toit/artemis-service-$(random 0x3fff_ffff)"

UPDATE_SYNCHRONIZED  /int ::= 0
UPDATE_CHANGE_STATE  /int ::= 1
UPDATE_CHANGE_CONFIG /int ::= 2

revision/int? := null
config/Map ::= {:}
max_offline/Duration? := null

new_config/Map? := null

client/mqtt.FullClient? := null
logger/log.Logger ::= log.default.with_name "artemis"

// Index in return value from `process_stats`.
BYTES_ALLOCATED ::= 4

class SynchronizeJob extends Job:
  device/ArtemisDevice
  constructor .device:

  next_run now/SchedulerTime -> SchedulerTime:
    if not last_run or not max_offline: return now
    return last_run + max_offline

  run -> none:
    synchronize device

synchronize device/ArtemisDevice:
  stats := List BYTES_ALLOCATED + 1  // Use this to collect stats to avoid allocation.
  allocated := (process_stats stats)[BYTES_ALLOCATED]
  updates := monitor.Channel 10
  logger.info "connecting to broker" --tags={"device": device.name}

  disconnect ::= run_client device updates
  try:
    while true:
      if handle_updates updates: continue
      new_allocated := (process_stats stats)[BYTES_ALLOCATED]
      delta := new_allocated - allocated
      logger.info "synchronized" --tags={"allocated": delta}
      allocated = new_allocated
      if max_offline:
        logger.info "going offline" --tags={"duration": max_offline}
        return
  finally:
    disconnect.call

run_client device/ArtemisDevice updates/monitor.Channel -> Lambda:
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
                  updates.send UPDATE_CHANGE_CONFIG
              else:
                // TODO(kasper): Maybe we should let the update handler decide
                // if we're synchronized or not?
                updates.send UPDATE_SYNCHRONIZED
            else if topic == device.topic_config:
              new_config = ubjson.decode publish.payload
              if revision == new_config["revision"]:
                updates.send UPDATE_CHANGE_CONFIG
            else if topic.starts_with "toit/apps/":
              // TODO(kasper): Hacky!
              path := topic.split "/"
              image := path[2]
              if not images_installed.contains image:
                payload := publish.payload_stream
                writer := containers.ContainerImageWriter payload.size
                while data := payload.read: writer.write data
                container_id := writer.commit
                logger.info "app install: done" --tags={"image": image, "container": container_id}
                images_installed[image] = container_id
                images_subscribed.remove topic
                client.unsubscribe topic
                containers.start container_id
                // Our local state has changed. Maybe we're done? Let
                // the update handler know.
                updates.send UPDATE_CHANGE_STATE
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

handle_updates updates/monitor.Channel -> bool:
  update := updates.receive
  if update == UPDATE_SYNCHRONIZED: return false

  if update == UPDATE_CHANGE_CONFIG:
    old := config.get "apps"
    existing := old ? old.copy : {:}

    apps := new_config.get "apps"
    if apps:
      apps.do: | key value |
        n := existing.get key
        if n != value:
          // New or updated app.
          if n:
            logger.info "app install: request" --tags={"name": key, "image": value, "old": n}
          else:
            logger.info "app install: request" --tags={"name": key, "image": value}
          existing[key] = value
    existing.copy.do: | key value |
      if apps and apps.get key: continue.do
      logger.info "app uninstall" --tags={"name": key}
      existing.remove key

    // Commit.
    config["apps"] = existing

    // TODO(kasper): Should this just stay in config?
    if new_config.contains "max-offline":
      max_offline = Duration --s=new_config["max-offline"]
    else:
      max_offline = null

    images_subscribed = {}
    (compute_image_topics config).do:
      if client: client.subscribe it
      images_subscribed.add it
    if old:
      old.do: | key value |
        if not existing.contains key:
          cnt := images_installed.get value
          if client: client.unsubscribe "toit/apps/$value/image$BITS_PER_WORD"
          if cnt: containers.uninstall cnt
          images_installed.remove value

  // state == UPDATE_CHANGE_STATE or state == UPDATE_CHANGE_CONFIG
  if not images_subscribed.is_empty: return true
  return false

images_installed := {:}
images_subscribed := {}

compute_image_topics config/Map -> List:
  apps := config.get "apps"
  if not apps: return []
  result := []
  apps.do: | key value |
    if images_installed.contains value: continue.do
    result.add "toit/apps/$value/image$BITS_PER_WORD"
  return result
