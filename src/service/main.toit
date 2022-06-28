import net
import mqtt
import mqtt.packets as mqtt
import monitor
import encoding.ubjson

import system.containers

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

// Index in return value from `process_stats`.
BYTES_ALLOCATED ::= 4

main arguments/List:
  stats := List BYTES_ALLOCATED + 1  // Use this to collect stats to avoid allocation.
  allocated := (process_stats stats)[BYTES_ALLOCATED]
  while true:
    updates := monitor.Channel 10

    disconnect ::= run_client updates

    catch --trace:
      while true:
        if handle_updates updates: continue
        new_allocated := (process_stats stats)[BYTES_ALLOCATED]
        delta := new_allocated - allocated
        print "Synchronized: $delta bytes allocated"
        allocated = new_allocated
        if max_offline: break

    disconnect.call

    if max_offline:
      print "Going offline for $(max_offline)"
      sleep max_offline
    else:
      print "Reconnecting to attempt to recover"
      sleep --ms=500

run_client updates/monitor.Channel -> Lambda:
  transport := create_transport
  client = mqtt.FullClient --transport=transport

  // Since we are using `retain` for important data, we simply connect
  // with the clean-session flag. The broker does not need to save
  // QoS packets that aren't retained.
  options := mqtt.SessionOptions
      --client_id=CLIENT_ID
      --clean_session

  client.connect --options=options

  disconnected := monitor.Latch

  // Add the topics we care about.
  subscribed_to_config := false

  handle_task/Task_? := ?
  handle_task = task::
    catch --trace:
      try:
        client.handle: | packet/mqtt.Packet |
          if packet is mqtt.PublishPacket:
            publish := packet as mqtt.PublishPacket
            topic := publish.topic
            payload := publish.payload
            if topic == TOPIC_REVISION:
              new_revision := ubjson.decode payload
              if new_revision != revision:
                revision = new_revision
                if not subscribed_to_config:
                  subscribed_to_config = true
                  client.subscribe TOPIC_CONFIG
                if new_config and revision == new_config["revision"]:
                  updates.send UPDATE_CHANGE_CONFIG
              else:
                // TODO(kasper): Maybe we should let the update handler decide
                // if we're synchronized or not?
                updates.send UPDATE_SYNCHRONIZED
            else if topic == TOPIC_CONFIG:
              new_config = ubjson.decode payload
              if revision == new_config["revision"]:
                updates.send 2
            else if topic.starts_with "toit/apps/":
              // TODO(kasper): Hacky!
              print "Got $topic post"
              x := topic.split "/"
              image := x[2]
              if not images_installed.contains image:
                writer := containers.ContainerImageWriter payload.size
                writer.write payload
                cnt := writer.commit
                print "Installed image for app ($image -> $cnt)"
                images_installed[image] = cnt
                images_subscribed.remove topic
                client.unsubscribe topic
                containers.start cnt
                // Our local state has changed. Maybe we're done? Let
                // the update handler know.
                updates.send UPDATE_CHANGE_STATE
          disconnected.set true
      finally:
        client = null
        handle_task = null

  // Wait for the client to run.
  client.when_running: null

  client.subscribe TOPIC_REVISION
  disconnect_lambda := ::
    if client:
      c := client
      client = null
      c.close
      exception := with_timeout --ms=3_000:
        disconnected.get
      if exception: c.close --force
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
            print "App reinstalled: $key | $n -> $value"
          else:
            print "App installed: $key | $value"
          existing[key] = value
    existing.copy.do: | key value |
      if apps and apps.get key: continue.do
      print "App uninstalled: $key"
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
      if client:
        print "Subscribing to $it"
        client.subscribe it
      images_subscribed.add it
    if old:
      old.do: | key value |
        if not existing.contains key:
          cnt := images_installed.get value
          if client: client.unsubscribe "toit/apps/$value/image"
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
    result.add "toit/apps/$value/image"
  return result
