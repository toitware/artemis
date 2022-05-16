import net
import mqtt
import monitor
import crypto.sha1

import encoding.ubjson
import encoding.json

import services.arguments
import host.file

import ..shared.connect

CLIENT_ID ::= "toit/artemis-client-$(random 0x3fff_ffff)"

// TODO:
//  - groups of devices
//  - device reject of configuration

main args:
  parser := arguments.ArgumentParser
  parser.add_command "install"
  parser.add_command "uninstall"
  parser.add_command "set-max-offline"

  parsed/arguments.Arguments := parser.parse args
  if parsed.command == "install":
    update_config: | config/Map client/mqtt.Client |
      install_app parsed config client
  else if parsed.command == "uninstall":
    update_config: | config/Map client/mqtt.Client |
      uninstall_app parsed config
  else if parsed.command == "set-max-offline":
    update_config: | config/Map client/mqtt.Client |
      set_max_offline parsed config

install_app args/arguments.Arguments config/Map client/mqtt.Client:
  app := args.rest[0]

  image_path := args.rest[1]
  image := file.read_content image_path
  sha := sha1.Sha1
  sha.add image
  checksum := ""
  sha.get.do: checksum += "$(%02x it)"
  client.publish "toit/apps/$checksum/image" image --qos=1 --retain

  print "$(%08d Time.monotonic_us): Installing app: $app"
  apps := config.get "apps" --if_absent=: {:}
  apps[app] = checksum
  config["apps"] = apps
  return config

uninstall_app args/arguments.Arguments config/Map:
  app := args.rest[0]
  print "$(%08d Time.monotonic_us): Uninstalling app: $app"
  apps := config.get "apps"
  if not apps: return config
  apps.remove app
  return config

set_max_offline args/arguments.Arguments config/Map:
  max_offline := int.parse args.rest[0]
  print "$(%08d Time.monotonic_us): Setting max-offline to $(Duration --s=max_offline)"
  if max_offline > 0:
    config["max-offline"] = max_offline
  else:
    config.remove "max-offline"
  return config

update_config [block]:
  socket := open_socket
  client/mqtt.Client? := null
  receiver := null
  try:
    client = open_client CLIENT_ID socket

    locked := monitor.Latch
    config_channel := monitor.Channel 1
    revision_channel := monitor.Channel 1
    me := "cli-$(random 0x3fff_ffff)-$(Time.now.ns_part)"

    others := 0
    client.subscribe TOPIC_LOCK --qos=1
    receiver = task::
      try:
        client.handle: | topic/string payload/ByteArray |
          if topic == TOPIC_LOCK:
            writer := ubjson.decode payload
            if not writer:
              others = 0
              print "$(%08d Time.monotonic_us): Trying to acquire lock"
              client.publish TOPIC_LOCK (ubjson.encode me)  --qos=1 --retain
            else if writer == me:
              if others == 0:
                print "$(%08d Time.monotonic_us): Acquired lock"
                locked.set me
              else:
                // Someone else locked this before us. Just wait.
                print "$(%08d Time.monotonic_us): Another writer acquired the lock"
            else:
              others++
          else if topic == TOPIC_CONFIG:
            if not config_channel.try_send (ubjson.decode payload):
              // TODO(kasper): Tell main task.
              throw "FATAL: Received too many configs"
          else if topic == TOPIC_REVISION:
            if not revision_channel.try_send (ubjson.decode payload):
              // TODO(kasper): Tell main task.
              throw "FATAL: Received too many revision"
      finally:
        receiver = null

    exception := catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
      with_timeout --ms=5_000:
        locked.get
    if exception == DEADLINE_EXCEEDED_ERROR and others == 0:
      print "$(%08d Time.monotonic_us): Trying to initialize writer lock"
      client.publish TOPIC_LOCK (ubjson.encode me) --qos=1 --retain

      exception = catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=5_000:
          locked.get
      if exception == DEADLINE_EXCEEDED_ERROR:
        print "$(%08d Time.monotonic_us): Timed out waiting for writer lock"
        return

    try:
      catch --trace --unwind:
        client.subscribe TOPIC_CONFIG --qos=1
      catch --trace --unwind:
        client.subscribe TOPIC_REVISION --qos=1

      config := null
      exception = catch --trace --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=5_000:
          config = config_channel.receive
      if exception == DEADLINE_EXCEEDED_ERROR:
        print "$(%08d Time.monotonic_us): Trying to initialize config"
        client.publish TOPIC_CONFIG (ubjson.encode {"revision": 0}) --qos=1 --retain
        client.publish TOPIC_REVISION (ubjson.encode 0) --qos=1 --retain

        exception = catch --trace --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
          with_timeout --ms=5_000:
            config = config_channel.receive
        if exception == DEADLINE_EXCEEDED_ERROR:
          print "$(%08d Time.monotonic_us): Timed out waiting for config"
          return

      old_revision := revision_channel.receive
      if old_revision != config["revision"]:
        throw "FATAL: Revision mismatch"

      revision := old_revision + 1
      config["writer"] = me
      config["revision"] = revision
      config = block.call config client

      // TODO(kasper): Maybe validate the config?
      client.publish TOPIC_CONFIG (ubjson.encode config) --qos=1 --retain
      if config_channel.receive["writer"] != me:
        throw "FATAL: Wrong writer in updated config"

      client.publish TOPIC_REVISION (ubjson.encode revision) --qos=1 --retain
      if revision_channel.receive != revision:
        throw "FATAL: Wrong revision in updated config"

      print "Updated config to $config"

    finally:
      if receiver: receiver.cancel
      critical_do:
        print "$(%08d Time.monotonic_us): Releasing lock"
        client.publish TOPIC_LOCK (ubjson.encode null) --qos=1 --retain

  finally:
    if client: client.close
