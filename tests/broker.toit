// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import log show Logger
import monitor
import mqtt
import net

import supabase

import .mqtt_broker_mosquitto
import .supabase_local_server
import ..tools.http_servers.broker show HttpBroker
import ..tools.http_servers.broker as http_servers
import artemis.shared.server_config
  show
    ServerConfig ServerConfigHttpToit ServerConfigSupabase ServerConfigMqtt
import .utils

class TestBroker:
  server_config/ServerConfig
  backdoor/BrokerBackdoor

  constructor .server_config .backdoor:

interface BrokerBackdoor:
  /**
  Creates a new device with the given $device_id and initial $state.
  */
  create_device --device_id/string --state/Map={:} -> none

  /**
  Removes the device with the given $device_id.
  */
  remove_device device_id/string -> none

with_broker --type/string --logger/Logger [block]:
  if type == "supabase":
    server_config := get_supabase_config --sub_directory=SUPABASE_CUSTOMER
    service_key := get_supabase_service_key --sub_directory=SUPABASE_CUSTOMER
    server_config.poll_interval = Duration --ms=1
    backdoor := SupabaseBackdoor server_config service_key
    test_server := TestBroker server_config backdoor
    block.call test_server
  else if type == "http":
    with_http_broker block
  else if type == "mosquitto":
    with_mosquitto --logger=logger: | host/string port/int |
      server_config := ServerConfigMqtt "mosquitto" --host=host --port=port
      backdoor := MqttBackdoor server_config --logger=logger
      test_server := TestBroker server_config backdoor
      block.call test_server
  else:
    throw "Unknown Artemis server type: $type"

class ToitHttpBackdoor implements BrokerBackdoor:
  server/HttpBroker

  constructor .server:

  create_device --device_id/string --state/Map={:}:
    server.create_device --device_id=device_id --state=state

  remove_device device_id/string -> none:
    server.remove_device device_id

with_http_broker [block]:
  server := http_servers.HttpBroker 0
  port_latch := monitor.Latch
  server_task := task:: server.start port_latch

  server_config := ServerConfigHttpToit "test-broker"
      --host="localhost"
      --port=port_latch.get

  backdoor/ToitHttpBackdoor := ToitHttpBackdoor server

  test_server := TestBroker server_config backdoor
  try:
    block.call test_server
  finally:
    server.close
    server_task.cancel

class SupabaseBackdoor implements BrokerBackdoor:
  server_config_/ServerConfigSupabase
  service_key_/string

  constructor .server_config_ .service_key_:

  create_device --device_id/string --state/Map={:}:
    with_backdoor_client_: | client/supabase.Client |
      client.rest.rpc "toit_artemis.new_provisioned" {
        "_device_id": device_id,
        "_state": state,
      }

  remove_device device_id/string -> none:
    with_backdoor_client_: | client/supabase.Client |
      client.rest.rpc "toit_artemis.remove_device" {
        "_device_id": device_id,
      }

  with_backdoor_client_ [block]:
    network := net.open
    supabase_client/supabase.Client? := null
    try:
      supabase_client = supabase.Client
          --host=server_config_.host
          --anon=service_key_
      block.call supabase_client
    finally:
      if supabase_client: supabase_client.close
      network.close

class MqttBackdoor implements BrokerBackdoor:
  server_config_/ServerConfigMqtt
  logger_/Logger

  constructor .server_config_ --logger/Logger:
    logger_ = logger

  create_device --device_id/string --state/Map={:}:
    // TODO(florian): implement MQTT create-device.

  remove_device device_id/string -> none:
    // TODO(florian): implement MQTT remove-device.

  with_backdoor_client_ [block]:
    network := net.open
    transport := mqtt.TcpTransport
        network
        --host=server_config_.host
        --port=server_config_.port
    mqtt_client := mqtt.Client --transport=transport --logger=logger_
    try:
      mqtt_client.start
      block.call mqtt_client
    finally:
      mqtt_client.close
      network.close
