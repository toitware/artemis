// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import encoding.ubjson
import log show Logger
import log
import monitor
import mqtt
import net

import supabase

import artemis.cli.brokers.broker show BrokerCli
import artemis.service.brokers.broker show BrokerService

import .mqtt_broker_mosquitto
import .mqtt_broker_toit
import .supabase_local_server
import ..tools.http_servers.broker show HttpBroker
import ..tools.http_servers.broker as http_servers
import artemis.shared.server_config
  show
    ServerConfig
    ServerConfigHttpToit
    ServerConfigSupabase
    ServerConfigMqtt
import artemis.shared.mqtt
  show
    topic_state_for
    topic_goal_for
    topic_revision_for
import .utils

class TestBroker:
  server_config/ServerConfig
  backdoor/BrokerBackdoor

  constructor .server_config .backdoor:

interface BrokerBackdoor:
  /**
  Creates a new device with the given $device_id and initial $state.
  */
  create_device --device_id/string --state/Map -> none

  /**
  Removes the device with the given $device_id.
  */
  remove_device device_id/string -> none

  /**
  Returns the reported state of the device.
  */
  get_state device_id/string -> Map?

with_broker --type/string --logger/Logger [block]:
  if type == "supabase-local" or type == "supabase-local-artemis":
    sub_dir := type == "supabase-local" ? SUPABASE_CUSTOMER : SUPABASE_ARTEMIS
    server_config := get_supabase_config --sub_directory=sub_dir
    service_key := get_supabase_service_key --sub_directory=sub_dir
    server_config.poll_interval = Duration --ms=1
    backdoor := SupabaseBackdoor server_config service_key
    test_server := TestBroker server_config backdoor
    block.call test_server
  else if type == "http" or type == "http-toit":
    with_http_broker block
  else if type == "mosquitto":
    with_mosquitto --logger=logger: | host/string port/int |
      server_config := ServerConfigMqtt "mosquitto" --host=host --port=port
      backdoor := MqttBackdoor server_config --logger=logger
      test_server := TestBroker server_config backdoor
      block.call test_server
  else if type == "toit-mqtt":
    // TODO(florian): reenable the Toit MQTT broker.
    // The service and cli currently need to be instantiated with
    // --create_transport.
    // However, that would add too many special cases.
    throw "UNIMPLEMENTED"
  else:
    throw "Unknown broker type: $type"

/**
Starts the broker of the given type and calls the given [block] with
  the $type, the broker-cli, and broker-service.
*/
with_brokers --type/string [block]:
  logger := log.default.with_name "testing-$type"
  with_broker --type=type --logger=logger: | broker/TestBroker |
    with_tmp_config: | config |
      broker_cli/BrokerCli? := null
      broker_service/BrokerService? := null
      try:
        broker_cli = BrokerCli broker.server_config config
        broker_service = BrokerService logger broker.server_config
        block.call logger type broker_cli broker_service
      finally:
        if broker_cli: broker_cli.close


class ToitHttpBackdoor implements BrokerBackdoor:
  server/HttpBroker

  constructor .server:

  create_device --device_id/string --state/Map:
    server.create_device --device_id=device_id --state=state

  remove_device device_id/string -> none:
    server.remove_device device_id

  get_state device_id/string -> Map?:
    return server.get_state --device_id=device_id

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

  create_device --device_id/string --state/Map:
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

  get_state device_id/string -> Map?:
    with_backdoor_client_: | client/supabase.Client |
      return client.rest.rpc "toit_artemis.get_state" {
        "_device_id": device_id,
      }
    unreachable

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

  create_device --device_id/string --state/Map:
    with_backdoor_client_: | client/mqtt.Client |
      topic := topic_state_for device_id
      client.publish topic (ubjson.encode state) --retain --qos=1

  remove_device device_id/string -> none:
    with_backdoor_client_: | client/mqtt.Client |
      [
        topic_state_for device_id,
        topic_goal_for device_id,
        topic_revision_for device_id,
      ].do: client.publish it #[] --retain --qos=1

  get_state device_id/string -> Map?:
    state_latch := monitor.Latch
    with_backdoor_client_: | client/mqtt.Client |
      topic := topic_state_for device_id
      client.subscribe topic:: | _ payload/ByteArray |
        if not state_latch.has_value:
          state_latch.set (ubjson.decode payload)
        client.unsubscribe topic
      return state_latch.get
    unreachable

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
