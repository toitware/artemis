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
import uuid

import ..broker
import ...device
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

  sign_in --provider/string --ui/Ui --open_browser/bool:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  update_goal --device_id/string [block] -> none:
    client := client_
    topic_lock := topic_lock_for device_id
    topic_goal := topic_goal_for device_id
    topic_state := topic_state_for device_id
    topic_revision := topic_revision_for device_id

    locked := monitor.Latch
    goal_channel := monitor.Channel 1
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
      // We send goal-state and revision changes with `--retain`.
      // As such we should get a packet as soon as we subscribe to the topics.

      state/Map? := null
      state_received_latch := monitor.Latch
      // The device can update the state at any time.
      // We subscribe to the state topic and wait for at least one packet.
      // If we happen to get another one before we return we will use that
      // one instead.
      client.subscribe topic_state:: | topic/string payload/ByteArray |
        // We use the latest state we receive.
        state = ubjson.decode payload
        if not state_received_latch.has_value:
          state_received_latch.set true

      client.subscribe topic_goal:: | topic/string payload/ByteArray |
        if not goal_channel.try_send (ubjson.decode payload):
          // TODO(kasper): Tell main task.
          throw "FATAL: Received too many goal states"

      client.subscribe topic_revision:: | topic/string payload/ByteArray |
        if not revision_channel.try_send (ubjson.decode payload):
          // TODO(kasper): Tell main task.
          throw "FATAL: Received too many revision"

      receiving_start_time_us := Time.monotonic_us

      // When using MQTT, the goal state is embedded into a goal packet, where
      // the packet contains meta information like the revision number.
      goal_packet := null
      exception = catch
          --trace=(: it != DEADLINE_EXCEEDED_ERROR)
          --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=retain_timeout_ms:
          goal_packet = goal_channel.receive
      if exception == DEADLINE_EXCEEDED_ERROR:
        log.info "$(%08d Time.monotonic_us): Trying to initialize goal"
        client.publish topic_goal (ubjson.encode {"revision": 0}) --qos=1 --retain
        client.publish topic_revision (ubjson.encode 0) --qos=1 --retain

        exception = catch --trace --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
          with_timeout --ms=retain_timeout_ms:
            goal_packet = goal_channel.receive
        if exception == DEADLINE_EXCEEDED_ERROR:
          log.info "$(%08d Time.monotonic_us): Timed out waiting for goal"
          return

      old_revision := revision_channel.receive
      if old_revision != goal_packet["revision"]:
        throw "FATAL: Revision mismatch"

      revision := old_revision + 1
      goal_packet["writer"] = me
      goal_packet["revision"] = revision

      if not state_received_latch.has_value:
        exception = catch
            --trace=(: it != DEADLINE_EXCEEDED_ERROR)
            --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
          remaining_time_ms := retain_timeout_ms - (Time.monotonic_us - receiving_start_time_us)/1000
          with_timeout --ms=remaining_time_ms:
            state_received_latch.get
        if exception == DEADLINE_EXCEEDED_ERROR:
          // Either the broker is not fast enough in responding, or
          // the broker lost the state (despite it being retained), or
          // the device didn't send any state yet, and the initial state
          // wasn't correctly set.
          log.info "$(%08d Time.monotonic_us): Timed out waiting for state"
          return

      // TODO(florian): change the timeout depending on how long we already waited.
      with_timeout --ms=retain_timeout_ms:
        state_received_latch.get

      // TODO(florian): also get the current state of the device.
      device := DeviceDetailed --goal=(goal_packet.get "goal") --state=state
      new_goal := block.call device

      goal_packet["goal"] = new_goal

      // TODO(kasper): Maybe validate the goal?
      client.publish topic_goal (ubjson.encode goal_packet) --qos=1 --retain
      if goal_channel.receive["writer"] != me:
        throw "FATAL: Wrong writer in updated goal"

      client.publish topic_revision (ubjson.encode revision) --qos=1 --retain
      if revision_channel.receive != revision:
        throw "FATAL: Wrong revision in updated goal"

      log.info "Updated goal packet to $goal_packet"

    finally:
      critical_do:
        log.info "$(%08d Time.monotonic_us): Releasing lock"
        client.publish topic_lock (ubjson.encode null) --retain

  get_device --device_id/string -> DeviceDetailed:
    throw "UNIMPLEMENTED"

  upload_image -> none
      --organization_id/string
      --app_id/uuid.Uuid
      --word_size/int
      content/ByteArray:
    upload_resource_ "toit/$organization_id/apps/$app_id/image$word_size" content

  upload_firmware --organization_id/string --firmware_id/string parts/List -> none:
    upload_resource_in_parts_ "toit/$organization_id/firmware/$firmware_id" parts

  download_firmware --organization_id/string --id/string -> ByteArray:
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

  notify_created --device_id/string --state/Map -> none:
    // Publish the state on the state topic.
    topic := topic_state_for device_id
    client_.publish topic (ubjson.encode state) --qos=1 --retain

  print_status --device_id/string --ui/Ui -> none:
    topic_presence := topic_presence_for device_id
    topic_goal := topic_goal_for device_id

    with_timeout --ms=5_000:
      client := client_
      status := monitor.Latch
      goal := monitor.Latch
      client.subscribe topic_presence:: | topic/string payload/ByteArray |
        status.set payload.to_string
      client.subscribe topic_goal:: | topic/string payload/ByteArray |
        goal.set (ubjson.decode payload)
      ui.info "Device: $device_id"
      ui.info "  $status.get"
      ui.info "  $goal.get"

  watch_presence --ui/Ui -> none:
    client := client_
    client.subscribe "toit/devices/presence/#":: | topic/string payload/ByteArray |
      device_name := (topic.split "/").last
      ui.info "$(%08d Time.monotonic_us): $device_name: $payload.to_string"
    // Wait forever.
    (monitor.Latch).get
