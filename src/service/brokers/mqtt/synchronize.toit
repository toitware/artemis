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
import ....shared.mqtt
import ....shared.server_config

CLIENT_ID ::= "toit/artemis-service-$(random 0x3fff_ffff)"

class BrokerServiceMqtt implements BrokerService:
  revision_/int? := null
  logger_/log.Logger
  create_transport_/Lambda

  constructor .logger_ --server_config/ServerConfigMqtt:
    create_transport_ = :: | network/net.Interface |
      create_transport_from_server_config network server_config
          --certificate_provider=: throw "UNSUPPORTED"

  constructor .logger_ --create_transport/Lambda:
    create_transport_ = create_transport

  connect --device_id/string --callback/EventHandler [block]:
    network ::= net.open
    check_in network logger_
    transport ::= create_transport_.call network
    client/mqtt.FullClient? := mqtt.FullClient --transport=transport
    connect_client_ --device_id=device_id client
    disconnected := monitor.Latch

    resources ::= ResourceManagerMqtt client

    topic_revision := topic_revision_for device_id
    topic_goal := topic_goal_for device_id
    topic_presence := topic_presence_for device_id

    sub_ack_latch := monitor.Latch

    handle_task/Task? := ?
    handle_task = task --background::
      try:
        subscribed_to_config := false
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
                if not subscribed_to_config:
                  subscribed_to_config = true
                  client.subscribe topic_goal
                if new_goal_packet and revision_ == new_goal_packet["revision"]:
                  callback.handle_goal (new_goal_packet.get "goal") resources
                  new_goal_packet = null
              else:
                // Maybe we're done? We let the synchronization task
                // know so it can react to the changed state.
                callback.handle_nop
            else if topic == topic_goal:
              new_goal_packet = ubjson.decode publish.payload
              if revision_ == new_goal_packet["revision"]:
                callback.handle_goal (new_goal_packet.get "goal") resources
                new_goal_packet = null
            else:
              known := resources.provide_resource topic: publish.payload_stream
              if not known: logger_.warn "unhandled publish packet" --tags={"topic": topic}
          else if packet is mqtt.SubAckPacket:
            sub_ack_id := (packet as mqtt.SubAckPacket).packet_id
            if not sub_ack_latch.has_value:
              sub_ack_latch.set sub_ack_id

      finally:
        critical_do:
          disconnected.set true
          client.close --force
          transport.close
          network.close
        client = null
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
      block.call resources
    finally:
      try:
        if client: client.publish topic_presence "offline".to_byte_array --retain
        if client: client.close
        with_timeout --ms=3_000: disconnected.get
      finally:
        if handle_task: handle_task.cancel

  on_idle -> none:
    // Do nothing.

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
