// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import log
import monitor
import mqtt
import mqtt.packets as mqtt
import net

import .resources
import ..applications
import ..synchronize show SynchronizeJob
import ...shared.connect

CLIENT_ID ::= "toit/artemis-service-$(random 0x3fff_ffff)"

class SynchronizeJobMqtt extends SynchronizeJob:
  revision_/int? := null
  config_/Map := {:}

  constructor logger/log.Logger device/DeviceMqtt applications/ApplicationManager:
    super logger device applications

  commit config/Map actions/List -> Lambda:
    return ::
      actions.do: it.call
      config_ = config

  connect [block]:
    device ::= device_ as DeviceMqtt
    network ::= net.open
    transport ::= create_transport network
    client/mqtt.FullClient? := mqtt.FullClient --transport=transport
    connect_client_ device client
    disconnected := monitor.Latch

    resources ::= ResourceManagerMqtt client

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
                if new_revision != revision_:
                  revision_ = new_revision
                  if not subscribed_to_config:
                    subscribed_to_config = true
                    client.subscribe device.topic_config
                  if new_config and revision_ == new_config["revision"]:
                    handle_update_config config_ new_config
                    new_config = null
                else:
                  // Maybe we're done? We let the synchronization task
                  // know so it can react to the changed state.
                  handle_nop
              else if topic == device.topic_config:
                new_config = ubjson.decode publish.payload
                if revision_ == new_config["revision"]:
                  handle_update_config config_ new_config
                  new_config = null
              else:
                known := resources.provide_resource topic: publish.payload_stream
                if not known: logger_.warn "unhandled publish packet" --tags={"topic": topic}
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
      block.call resources
    finally:
      try:
        if client: client.publish device.topic_presence "offline".to_byte_array --retain
        if client: client.close
        with_timeout --ms=3_000: disconnected.get
      finally:
        if handle_task: handle_task.cancel

  connect_client_ device/DeviceMqtt client/mqtt.FullClient -> none:
    last_will ::= mqtt.LastWill device.topic_presence "disappeared".to_byte_array
        --retain
        --qos=0
    // Since we are using `retain` for important data, we simply connect
    // with the clean-session flag. The broker does not need to save
    // QoS packets that aren't retained.
    options ::= mqtt.SessionOptions
        --client_id=CLIENT_ID
        --clean_session
        --last_will=last_will
    client.connect --options=options
