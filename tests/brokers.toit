// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor
import host.directory

import mqtt.transport as mqtt
import artemis.shared.broker_config show BrokerConfig BrokerConfigMqtt
import artemis.cli.broker show BrokerCli
import artemis.service.broker show BrokerService
import artemis.cli.brokers.mqtt.base show BrokerCliMqtt
import artemis.service.brokers.mqtt.synchronize show BrokerServiceMqtt
import artemis.cli.brokers.http.base show BrokerCliHttp
import artemis.service.brokers.http.synchronize show BrokerServiceHttp
import artemis.cli.brokers.postgrest.base show BrokerCliPostgrest
import artemis.cli.brokers.postgrest.supabase show create_broker_cli_supabase
import artemis.service.brokers.postgrest.synchronize show BrokerServicePostgrest
import artemis.shared.broker_config show BrokerConfigSupabase
import ..tools.http_broker.main as http_broker
import .mqtt_broker_mosquitto
import .mqtt_broker_toit
import .supabase_local_broker

/**
Starts the broker with the given $broker_id and calls the given [block] with
  the $broker_id, broker-cli, and broker-service.
*/
with_brokers broker_id [block]:
  logger := log.default.with_name "testing-$broker_id"
  if broker_id == "mosquitto":
    with_mosquitto --logger=logger: | host/string port/int |
      broker_config := BrokerConfigMqtt "mosquitto" --host=host --port=port
      with_mqtt_brokers_ logger broker_id --broker_config=broker_config block
  else if broker_id == "toit-mqtt":
    with_toit_mqtt_broker --logger=logger: | create_transport/Lambda |
      with_mqtt_brokers_ logger broker_id --create_transport=create_transport block
  else if broker_id == "http-toit":
    with_http_toit_brokers_ logger broker_id block
  else if broker_id == "supabase-local":
    // Here we are only interested in customer brokers.
    // We need to move into the customer-supabase directory to get its configuration.
    current_dir := directory.cwd
    try:
      directory.chdir "$current_dir/supabase_customer"
      with_supabase: | host/string anon/string |
        directory.chdir current_dir
        broker_config := BrokerConfigSupabase "supabase-local" --host=host --anon=anon
        with_postgrest_brokers_ logger broker_id broker_config block
    finally:
      directory.chdir current_dir
  else:
    throw "Unknown broker $broker_id"

with_mqtt_brokers_ logger/log.Logger broker_id/string
    --broker_config/BrokerConfigMqtt?=null
    --create_transport/Lambda?=null
    [block]:
  if not broker_config and not create_transport: throw "INVALID_ARGUMENT"
  if broker_config and create_transport: throw "INVALID_ARGUMENT"
  broker_cli/BrokerCli? := null
  broker_service/BrokerService? := null
  try:
    if broker_config:
      broker_service = BrokerServiceMqtt logger --broker_config=broker_config
      broker_cli = BrokerCliMqtt --broker_config=broker_config --id="test/$broker_id"
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
    broker_config/BrokerConfigSupabase
    [block]:
  broker_config.config_["poll_interval"] = 1000 // us.
  broker_service := BrokerServicePostgrest logger broker_config
  broker_cli := create_broker_cli_supabase broker_config
  try:
    block.call logger broker_id broker_cli broker_service
  finally:
    broker_cli.close

