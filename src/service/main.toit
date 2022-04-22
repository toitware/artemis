import net
import mqtt
import monitor
import encoding.ubjson

import system.containers

import ..shared.connect

CLIENT_ID ::= "toit/tiger-service-$(random 0x3fff_ffff)"
HOST      ::= "localhost"
PORT      ::= 1883

TOPIC_CONFIG   ::= "toit/devices/fisk/config"
TOPIC_REVISION ::= TOPIC_CONFIG + "/revision"

revision/int? := null

config/Map ::= {:}
new_config/Map? := null

client/mqtt.Client? := null

main arguments/List:
  max_offline/Duration? := null
  if arguments.size > 0:
    max_offline = Duration --s=(int.parse arguments[0])

  while true:
    bytes_allocated_delta
    updates := monitor.Channel 10
    connection_task := null
    connection_task = task::
      try:
        handle_connection updates
      finally:
        connection_task = null

    catch --trace:
      while handle_updates updates or not max_offline:
        // Keep going.

    // print_objects
    connection_task.cancel
    allocated := bytes_allocated_delta
    print "Synchronized: $allocated bytes"

    if max_offline:
      print "Going offline for $(max_offline) seconds"
      sleep max_offline
    else:
      print "Reconnecting to attempt to recover"
      sleep --ms=500

handle_connection updates/monitor.Channel:
  socket := open_socket
  try:
    client = open_client CLIENT_ID socket
    client.subscribe TOPIC_REVISION --qos=1

    // add the topics we care about.

    client.handle: | topic/string payload/ByteArray |
      if topic == TOPIC_REVISION:
        new_revision := ubjson.decode payload
        if new_revision != revision:
          client.subscribe TOPIC_CONFIG --qos=1
        else:
          updates.send 0
      else if topic == TOPIC_CONFIG:
        new_config = ubjson.decode payload
        revision = new_config["revision"]
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
          updates.send 1
  finally:
    if client:
      c := client
      client = null
      c.close
    socket.close

handle_updates updates/monitor.Channel -> bool:
  state := updates.receive
  if state == 0: return false

  new_revision := new_config["revision"]
  if state == 2:
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

    images_subscribed = {}
    (compute_image_topics config).do:
      if client:
        print "Subscribing to $it"
        client.subscribe it --qos=1
      images_subscribed.add it
    if old:
      old.do: | key value |
        if not existing.contains key:
          cnt := images_installed.get value
          if client: client.unsubscribe "toit/apps/$value/image"
          if cnt: containers.uninstall cnt
          images_installed.remove value

  // state == 1 or state == 2
  if not images_subscribed.is_empty: return true
  if new_revision != revision: return true
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

