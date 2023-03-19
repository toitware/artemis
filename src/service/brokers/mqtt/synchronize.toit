// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import log
import monitor
import mqtt
import mqtt.packets as mqtt
import net

import .resources
import ...check_in show check_in

import ..broker
import ...device
import ....shared.mqtt
import ....shared.server_config

CLIENT_ID ::= "toit/artemis-service-$(random 0x3fff_ffff)"

class BrokerServiceMqtt implements BrokerService:
  revision_/int? := null
  logger_/log.Logger
  create_transport_/Lambda

  signal_/monitor.Signal? := null
  goal_got_it_/bool := false
  goal_new_/Map? := null

  constructor .logger_ --server_config/ServerConfigMqtt:
    create_transport_ = :: | network/net.Interface |
      create_transport_from_server_config network server_config
          --certificate_provider=: throw "UNSUPPORTED"

  constructor .logger_ --create_transport/Lambda:
    create_transport_ = create_transport

  connect --device/Device [block]:
    network ::= net.open
    check_in network logger_ --device=device
    transport ::= create_transport_.call network
    client/mqtt.FullClient? := mqtt.FullClient --transport=transport

    device_id := device.id
    connect_client_ --device_id=device_id client
    disconnected := monitor.Latch
    signal := monitor.Signal

    resources ::= ResourceManagerMqtt device client

    topic_revision := topic_revision_for device_id
    topic_goal := topic_goal_for device_id
    topic_presence := topic_presence_for device_id

    sub_ack_latch := monitor.Latch

    handle_task/Task? := ?
    handle_task = task --background::
      try:
        subscribed_to_goal := false
        // For MQTT the goal is wrapped into a packet that contains
        // additional information like the revision.
        new_goal_packet/Map? := null
        client.handle: | packet/mqtt.Packet |
          if packet is mqtt.PublishPacket:
            publish := packet as mqtt.PublishPacket
            topic := publish.topic
            if topic == topic_revision:
              new_revision := ubjson.decode publish.payload
              if new_revision != revision_:
                revision_ = new_revision
                if not subscribed_to_goal:
                  subscribed_to_goal = true
                  client.subscribe topic_goal
                else if new_goal_packet and revision_ == new_goal_packet["revision"]:
                  goal_got_it_ = true
                  goal_new_ = new_goal_packet
                  signal.raise
                  new_goal_packet = null
            else if topic == topic_goal:
              new_goal_packet = ubjson.decode publish.payload
              if revision_ == new_goal_packet["revision"]:
                goal_got_it_ = true
                goal_new_ = new_goal_packet
                signal.raise
                new_goal_packet = null
            else:
              known := resources.provide_resource topic: publish.payload_stream
              if not known: logger_.warn "unhandled publish packet" --tags={"topic": topic}
          else if packet is mqtt.SubAckPacket:
            sub_ack_id := (packet as mqtt.SubAckPacket).packet_id
            if not sub_ack_latch.has_value:
              sub_ack_latch.set sub_ack_id

      finally:
        critical_do: disconnected.set true
        handle_task = null

    try:
      // Wait for the client to run.
      client.when_running: null
      client.publish topic_presence "online".to_byte_array --retain
      subscribe_to_revisions_packet_id := -1
      packet_id := client.subscribe topic_revision
      // Wait for the subscription to be acknowledged.
      // This isn't strictly necessary, but makes the code more deterministic.
      sub_ack_id := sub_ack_latch.get
      if packet_id != sub_ack_id:
        throw "Bad SubAck ID: $packet_id != $sub_ack_id"
      signal_ = signal
      block.call resources
    finally:
      signal_ = null
      try:
        if client: client.publish topic_presence "offline".to_byte_array --retain
        if client: client.close
        with_timeout --ms=3_000: disconnected.get
      finally:
        if handle_task:
          handle_task.cancel
          disconnected.get
      client.close --force
      transport.close
      network.close

  connect_client_ --device_id/string client/mqtt.FullClient -> none:
    topic_presence := topic_presence_for device_id

    // On slower platforms where the overhead for processing packets is high,
    // we can avoid a number of unwanted retransmits from the broker by using
    // a higher 'keep alive' setting. The slowest packet processing is for
    // firmware updates on the ESP32, where we need to erase and write to the
    // flash as we read the payload stream.
    keep_alive := platform == PLATFORM_FREERTOS
        ? Duration --m=3
        : Duration --m=1
    last_will ::= mqtt.LastWill topic_presence "disappeared".to_byte_array
        --retain
        --qos=0
    // Since we are using `retain` for important data, we simply connect
    // with the clean-session flag. The broker does not need to save
    // QoS packets that aren't retained.
    options ::= mqtt.SessionOptions
        --client_id=CLIENT_ID
        --clean_session
        --keep_alive=keep_alive
        --last_will=last_will
    client.connect --options=options

  fetch_new_goal --wait/bool -> Map?:
    while not goal_got_it_:
      if not wait: throw DEADLINE_EXCEEDED_ERROR
      signal_.wait: goal_got_it_
    result := goal_new_
    goal_got_it_ = false
    goal_new_ = null
    return result
