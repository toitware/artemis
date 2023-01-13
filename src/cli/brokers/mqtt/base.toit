// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor
import mqtt
import mqtt.transport as mqtt
import net
import net.x509
import encoding.ubjson
import tls
import certificate_roots

import ..broker
import ...ui
import ....shared.mqtt
import ....shared.server_config

create_broker_cli_mqtt server_config/ServerConfigMqtt:
  id := "mqtt/$server_config.host"
  return BrokerCliMqtt --server_config=server_config --id=id

class BrokerCliMqtt implements BrokerCli:
  static ID_ ::= "toit/artemis-cli-$(random 0x3fff_ffff)"

  client_/mqtt.Client? := null
  /** See $BrokerCli.id. */
  id/string

  transport_/mqtt.Transport

  /**
  The timeout, in ms, we are willing to wait for retained messages.

  Should generally be kept at a high level, as it only triggers if a retained
    message isn't available, or if a device is contacted the first time.

  Can be changed to something lower for tests.
  */
  retain_timeout_ms := 5_000

  constructor --server_config/ServerConfigMqtt --id/string:
    return BrokerCliMqtt --id=id --create_transport=:: | network/net.Interface |
      create_transport_from_server_config network server_config
          --certificate_provider=: certificate_roots.MAP[it]

  constructor --create_transport/Lambda --.id/string:
    network := net.open
    transport_ = create_transport.call network
    client_ = mqtt.Client --transport=transport_
    options := mqtt.SessionOptions --client_id=ID_ --clean_session
    client_.start --options=options

  close:
    client_.close
    transport_.close
    client_ = null

  is_closed -> bool:
    return client_ == null

  ensure_authenticated [block]:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  sign_up --email/string --password/string:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  sign_in --email/string --password/string:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  sign_in --provider/string --ui/Ui:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  device_update_config --device_id/string [block] -> none:
    client := client_
    topic_lock := topic_lock_for_ device_id
    topic_config := topic_config_for_ device_id
    topic_revision := topic_revision_for_ device_id

    locked := monitor.Latch
    config_channel := monitor.Channel 1
    revision_channel := monitor.Channel 1
    me := "cli-$(random 0x3fff_ffff)-$(Time.now.ns_part)"

    others := 0
    client.subscribe topic_lock:: | topic/string payload/ByteArray |
      writer := ubjson.decode payload
      if not writer:
        others = 0
        // TODO(florian): Make this real 'log' entries.
        log.info "$(%08d Time.monotonic_us): Trying to acquire lock"
        client.publish topic_lock (ubjson.encode me)  --qos=1 --retain
      else if writer == me:
        if others == 0:
          log.info "$(%08d Time.monotonic_us): Acquired lock"
          locked.set me
        else:
          // Someone else locked this before us. Just wait.
          log.info "$(%08d Time.monotonic_us): Another writer acquired the lock"
      else:
        others++

    // We use the '--retain' flag when trying to acquire the lock.
    // If nobody ever took the lock, then we might need to wait for the
    // timeout here. Otherwise, the broker should send the current lock holder
    // immediately.
    exception := catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
      with_timeout --ms=retain_timeout_ms:
        locked.get
    if exception == DEADLINE_EXCEEDED_ERROR and others == 0:
      // We assume that nobody has taken the lock so far.
      log.info "$(%08d Time.monotonic_us): Trying to initialize writer lock"
      client.publish topic_lock (ubjson.encode me) --qos=1 --retain

      exception = catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=retain_timeout_ms:
          locked.get

    // It doesn't matter wheter we got the lock or not. We don't want to
    // receive any messages on this topic anymore. Otherwise, we might
    // even fight for the lock just after we released it below.
    client.unsubscribe topic_lock

    if exception == DEADLINE_EXCEEDED_ERROR:
      // We didn't get the lock.
      // TODO(florian): in theory we might just now get the lock. However, we
      // will not release it. This could lead to a bad state.
      log.info "$(%08d Time.monotonic_us): Timed out waiting for writer lock"
      return

    try:
      // We send config and revision changes with `--retain`.
      // As such we should get a packet as soon as we subscribe to the topics.

      client.subscribe topic_config:: | topic/string payload/ByteArray |
        if not config_channel.try_send (ubjson.decode payload):
          // TODO(kasper): Tell main task.
          throw "FATAL: Received too many configs"

      client.subscribe topic_revision:: | topic/string payload/ByteArray |
        if not revision_channel.try_send (ubjson.decode payload):
          // TODO(kasper): Tell main task.
          throw "FATAL: Received too many revision"

      config := null
      exception = catch
          --trace=(: it != DEADLINE_EXCEEDED_ERROR)
          --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=retain_timeout_ms:
          config = config_channel.receive
      if exception == DEADLINE_EXCEEDED_ERROR:
        log.info "$(%08d Time.monotonic_us): Trying to initialize config"
        client.publish topic_config (ubjson.encode {"revision": 0}) --qos=1 --retain
        client.publish topic_revision (ubjson.encode 0) --qos=1 --retain

        exception = catch --trace --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
          with_timeout --ms=retain_timeout_ms:
            config = config_channel.receive
        if exception == DEADLINE_EXCEEDED_ERROR:
          log.info "$(%08d Time.monotonic_us): Timed out waiting for config"
          return

      old_revision := revision_channel.receive
      if old_revision != config["revision"]:
        throw "FATAL: Revision mismatch"

      revision := old_revision + 1
      config["writer"] = me
      config["revision"] = revision
      config = block.call config

      // TODO(kasper): Maybe validate the config?
      client.publish topic_config (ubjson.encode config) --qos=1 --retain
      if config_channel.receive["writer"] != me:
        throw "FATAL: Wrong writer in updated config"

      client.publish topic_revision (ubjson.encode revision) --qos=1 --retain
      if revision_channel.receive != revision:
        throw "FATAL: Wrong revision in updated config"

      log.info "Updated config to $config"

    finally:
      critical_do:
        log.info "$(%08d Time.monotonic_us): Releasing lock"
        client.publish topic_lock (ubjson.encode null) --retain

  upload_image --app_id/string --bits/int content/ByteArray -> none:
    upload_resource_ "toit/apps/$app_id/image$bits" content

  upload_firmware --firmware_id/string parts/List -> none:
    upload_resource_in_parts_ "toit/firmware/$firmware_id" parts

  download_firmware --id/string -> ByteArray:
    unreachable

  upload_resource_ path/string content/ByteArray -> none:
    client_.publish path content --qos=1 --retain

  upload_resource_in_parts_ path/string parts/List -> none:
    cursor := 0
    offsets := []
    parts.do: | part/ByteArray |
      offsets.add cursor
      upload_resource_ "$path/$cursor" part
      cursor += part.size
    manifest ::= ubjson.encode {
        "size": cursor,
        "parts": offsets,
    }
    upload_resource_ path manifest

  print_status --device_id/string --ui/Ui -> none:
    topic_presence := topic_presence_for_ device_id
    topic_config := topic_config_for_ device_id

    with_timeout --ms=5_000:
      client := client_
      status := monitor.Latch
      config := monitor.Latch
      client.subscribe topic_presence:: | topic/string payload/ByteArray |
        status.set payload.to_string
      client.subscribe topic_config:: | topic/string payload/ByteArray |
        config.set (ubjson.decode payload)
      ui.info "Device: $device_id"
      ui.info "  $status.get"
      ui.info "  $config.get"

  watch_presence --ui/Ui -> none:
    client := client_
    client.subscribe "toit/devices/presence/#":: | topic/string payload/ByteArray |
      device_name := (topic.split "/").last
      ui.info "$(%08d Time.monotonic_us): $device_name: $payload.to_string"
    // Wait forever.
    (monitor.Latch).get
