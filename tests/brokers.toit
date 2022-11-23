// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor

import mqtt.transport as mqtt
import artemis.shared.server_config show ServerConfig ServerConfigMqtt
import artemis.cli.brokers.broker show BrokerCli
import artemis.service.brokers.broker show BrokerService
import artemis.cli.brokers.mqtt.base show BrokerCliMqtt
import artemis.service.brokers.mqtt.synchronize show BrokerServiceMqtt
import artemis.cli.brokers.http.base show BrokerCliHttp
import artemis.service.brokers.http.synchronize show BrokerServiceHttp
import artemis.cli.brokers.postgrest.base show BrokerCliPostgrest
import artemis.cli.brokers.postgrest.supabase show create_broker_cli_supabase
import artemis.service.brokers.postgrest.synchronize show BrokerServicePostgrest
import artemis.shared.server_config show ServerConfigSupabase
import ..tools.http_servers.broker as http_broker
import .mqtt_broker_mosquitto
import .mqtt_broker_toit
import .supabase_local_server

/**
Starts the broker with the given $broker_id and calls the given [block] with
  the $broker_id, broker-cli, and broker-service.
*/
with_brokers broker_id [block]:
  logger := log.default.with_name "testing-$broker_id"
  if broker_id == "mosquitto":
    with_mosquitto --logger=logger: | host/string port/int |
      server_config := ServerConfigMqtt "mosquitto" --host=host --port=port
      with_mqtt_brokers_ logger broker_id --server_config=server_config block
  else if broker_id == "toit-mqtt":
    with_toit_mqtt_broker --logger=logger: | create_transport/Lambda |
      with_mqtt_brokers_ logger broker_id --create_transport=create_transport block
  else if broker_id == "http-toit":
    with_http_toit_brokers_ logger broker_id block
  else if broker_id == "supabase-local":
    // Here we are only interested in customer brokers.
    server_config := get_supabase_config --sub_directory="supabase_customer"
    with_postgrest_brokers_ logger broker_id server_config block
  else:
    throw "Unknown broker $broker_id"

with_mqtt_brokers_ logger/log.Logger broker_id/string
    --server_config/ServerConfigMqtt?=null
    --create_transport/Lambda?=null
    [block]:
  if not server_config and not create_transport: throw "INVALID_ARGUMENT"
  if server_config and create_transport: throw "INVALID_ARGUMENT"
  broker_cli/BrokerCli? := null
  broker_service/BrokerService? := null
  try:
    if server_config:
      broker_service = BrokerServiceMqtt logger --server_config=server_config
      broker_cli = BrokerCliMqtt --server_config=server_config --id="test/$broker_id"
    else:
      broker_service = BrokerServiceMqtt logger --create_transport=create_transport
      broker_cli = BrokerCliMqtt --create_transport=create_transport --id="test/$broker_id"

    block.call logger broker_id broker_cli broker_service
  finally:
    if broker_cli: broker_cli.close

with_http_toit_brokers_ logger/log.Logger broker_id/string [block]:
  broker := http_broker.HttpBroker 0
  port_latch := monitor.Latch
  broker_task := task:: broker.start port_latch
  try:
    broker_cli := BrokerCliHttp "localhost" port_latch.get --id="test/$broker_id"
    broker_service := BrokerServiceHttp logger "localhost" port_latch.get
    block.call logger broker_id broker_cli broker_service
  finally:
    broker.close
    broker_task.cancel

with_postgrest_brokers_
    logger/log.Logger
    broker_id/string
    server_config/ServerConfigSupabase
    [block]:
  server_config.config_["poll_interval"] = 1000 // us.
  broker_service := BrokerServicePostgrest logger server_config
  broker_cli := create_broker_cli_supabase server_config
  try:
    block.call logger broker_id broker_cli broker_service
  finally:
    broker_cli.close

