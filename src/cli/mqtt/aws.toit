// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import monitor
import mqtt
import encoding.ubjson

import .base
import ...shared.device

import ...shared.mqtt.aws
import ...shared.mqtt.base

class ClientAws extends ClientMqtt:
  static ID_ ::= "toit/artemis-client-$(random 0x3fff_ffff)"
  device/DeviceMqtt

  constructor device_name/string:
    device = DeviceMqtt device_name

  with_mqtt_ [block] -> none:
    network := net.open
    transport := aws_create_transport network
    client/mqtt.Client? := null
    try:
      client = mqtt.Client --transport=transport
      options := mqtt.SessionOptions --client_id=ID_ --clean_session
      client.start --options=options
      block.call client
    finally:
      if client: client.close
      network.close
