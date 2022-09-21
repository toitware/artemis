// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import monitor
import mqtt
import encoding.ubjson

import ..client
import ...shared.mqtt.base

abstract class ClientMqtt extends Client:
  client_/mqtt.Client? := null

  abstract device -> DeviceMqtt
  abstract with_mqtt_ [block] -> none

  update_config [block] -> none:
    with_mqtt_: | client/mqtt.Client |
      client_ = client  // TODO(kasper): Clear this again.
      locked := monitor.Latch
      config_channel := monitor.Channel 1
      revision_channel := monitor.Channel 1
      me := "cli-$(random 0x3fff_ffff)-$(Time.now.ns_part)"

      others := 0
      client.subscribe device.topic_lock:: | topic/string payload/ByteArray |
        writer := ubjson.decode payload
        if not writer:
          others = 0
          print "$(%08d Time.monotonic_us): Trying to acquire lock"
          client.publish device.topic_lock (ubjson.encode me)  --qos=1 --retain
        else if writer == me:
          if others == 0:
            print "$(%08d Time.monotonic_us): Acquired lock"
            locked.set me
          else:
            // Someone else locked this before us. Just wait.
            print "$(%08d Time.monotonic_us): Another writer acquired the lock"
        else:
          others++

      // We use the '--retain' flag when trying to acquire the lock.
      // If nobody ever took the lock, then we might need to wait for the
      // timeout here. Otherwise, the broker should send the current lock holder
      // immediately.
      exception := catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=5_000:
          locked.get
      if exception == DEADLINE_EXCEEDED_ERROR and others == 0:
        // We assume that nobody has taken the lock so far.
        print "$(%08d Time.monotonic_us): Trying to initialize writer lock"
        client.publish device.topic_lock (ubjson.encode me) --qos=1 --retain

        exception = catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
          with_timeout --ms=5_000:
            locked.get

      // We didn't get the lock.
      // TODO(florian): in theory we might just now get the lock. However, we
      // will not release it. This could lead to a bad state.
      if exception == DEADLINE_EXCEEDED_ERROR:
        print "$(%08d Time.monotonic_us): Timed out waiting for writer lock"
        return

      try:
        // We send config and revision changes with `--retain`.
        // As such we should get a packet as soon as we subscribe to the topics.

        client.subscribe device.topic_config:: | topic/string payload/ByteArray |
          if not config_channel.try_send (ubjson.decode payload):
            // TODO(kasper): Tell main task.
            throw "FATAL: Received too many configs"

        client.subscribe device.topic_revision:: | topic/string payload/ByteArray |
          if not revision_channel.try_send (ubjson.decode payload):
            // TODO(kasper): Tell main task.
            throw "FATAL: Received too many revision"

        config := null
        exception = catch
            --trace=(: it != DEADLINE_EXCEEDED_ERROR)
            --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
          with_timeout --ms=5_000:
            config = config_channel.receive
        if exception == DEADLINE_EXCEEDED_ERROR:
          print "$(%08d Time.monotonic_us): Trying to initialize config"
          client.publish device.topic_config (ubjson.encode {"revision": 0}) --qos=1 --retain
          client.publish device.topic_revision (ubjson.encode 0) --qos=1 --retain

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
        config = block.call config

        // TODO(kasper): Maybe validate the config?
        client.publish device.topic_config (ubjson.encode config) --qos=1 --retain
        if config_channel.receive["writer"] != me:
          throw "FATAL: Wrong writer in updated config"

        client.publish device.topic_revision (ubjson.encode revision) --qos=1 --retain
        if revision_channel.receive != revision:
          throw "FATAL: Wrong revision in updated config"

        print "Updated config to $config"

      finally:
        critical_do:
          print "$(%08d Time.monotonic_us): Releasing lock"
          client.publish device.topic_lock (ubjson.encode null) --retain

  upload_image id/string --bits/int content/ByteArray -> none:
    upload_resource_ "toit/apps/$id/image$bits" content

  upload_firmware id/string content/ByteArray -> none:
    upload_resource_in_parts_ "toit/firmware/$id" content

  upload_resource_ path/string content/ByteArray -> none:
    client_.publish path content --qos=1 --retain

  upload_resource_in_parts_ path/string content/ByteArray -> none:
    PART_SIZE ::= 64 * 1024
    cursor := 0
    parts := []
    while cursor < content.size:
      end := min content.size (cursor + PART_SIZE)
      parts.add cursor
      upload_resource_ "$path/$cursor" content[cursor..end]
      cursor = end
    manifest ::= ubjson.encode {
        "size": content.size,
        "parts": parts,
    }
    upload_resource_ path manifest

  print_status -> none:
    with_timeout --ms=5_000:
      with_mqtt_: | client/mqtt.Client |
        status := monitor.Latch
        config := monitor.Latch
        client.subscribe device.topic_presence:: | topic/string payload/ByteArray |
          status.set payload.to_string
        client.subscribe device.topic_config:: | topic/string payload/ByteArray |
          config.set (ubjson.decode payload)
        print "Device: $device.name"
        print "  $status.get"
        print "  $config.get"

  watch_presence -> none:
    with_mqtt_: | client/mqtt.Client |
      client.subscribe "toit/devices/presence/#":: | topic/string payload/ByteArray |
        device_name := (topic.split "/").last
        print "$(%08d Time.monotonic_us): $device_name: $payload.to_string"
      // Wait forever.
      (monitor.Latch).get
