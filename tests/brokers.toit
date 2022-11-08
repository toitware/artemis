// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor

import mqtt.transport as mqtt
import artemis.cli.broker show BrokerCli
import artemis.service.broker show BrokerService
import artemis.cli.brokers.mqtt.base show BrokerCliMqtt
import artemis.service.brokers.mqtt.synchronize show BrokerServiceMqtt
import artemis.cli.brokers.http.base show BrokerCliHttp
import artemis.service.brokers.http.synchronize show BrokerServiceHttp
import ..tools.http_broker.main as http_broker
import .mqtt_broker_mosquitto
import .mqtt_broker_toit

with_broker broker_id [block]:
  logger := log.default.with_name "testing-$broker_id"
  if broker_id == "mosquitto":
    with_mosquitto --logger=logger: | broker/Map |
      with_mqtt_broker logger broker_id broker block
  else if broker_id == "toit-mqtt":
    with_toit_mqtt_broker --logger=logger: | broker/Map |
      with_mqtt_broker logger broker_id broker block
  else if broker_id == "toit-http":
    with_toit_http_broker logger broker_id block
  else:
    throw "Unknown broker $broker_id"

with_mqtt_broker logger/log.Logger broker_id/string broker/Map [block]:
  broker_cli/BrokerCli? := null
  broker_service/BrokerService? := null
  try:
    broker_cli = BrokerCliMqtt broker --id="test/$broker_id"
    broker_service = BrokerServiceMqtt logger broker

    block.call logger broker_id broker_cli broker_service
  finally:
    if broker_cli: broker_cli.close

with_toit_http_broker logger/log.Logger broker_id/string [block]:
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

