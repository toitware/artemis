// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import monitor

import mqtt.transport as mqtt
import artemis.shared.mediator show MediatorCli
import artemis.service.mediator_service show MediatorService
import artemis.shared.mqtt.base show MediatorCliMqtt
import artemis.service.mqtt.synchronize show MediatorServiceMqtt
import artemis.shared.http.base show MediatorCliHttp
import artemis.service.http.synchronize show MediatorServiceHttp
import ..tools.http_broker.main as http_broker
import .mqtt_broker_mosquitto
import .mqtt_broker_toit

with_mediators mediators/List [block]:
  mediators.do: | mediator_id/string |
    logger := log.default.with_name "testing-$mediator_id"
    if mediator_id == "mosquitto":
      with_mosquitto --logger=logger: | create_transport/Lambda |
        with_mqtt_mediator logger mediator_id create_transport block
    else if mediator_id == "toit-mqtt":
      with_toit_mqtt_broker --logger=logger: | create_transport/Lambda |
        with_mqtt_mediator logger mediator_id create_transport block
    else if mediator_id == "toit-http":
      with_toit_http_mediator logger mediator_id block
    else:
      throw "Unknown mediator $mediator_id"

with_mqtt_mediator logger/log.Logger mediator_id/string create_transport/Lambda [block]:
  transport/mqtt.Transport := create_transport.call
  mediator_cli/MediatorCli? := null
  mediator_service/MediatorService? := null
  try:
    mediator_cli = MediatorCliMqtt transport --id="test/$mediator_id"
    mediator_service = MediatorServiceMqtt logger --create_transport=create_transport

    block.call logger mediator_id mediator_cli mediator_service
  finally:
    if mediator_cli: mediator_cli.close
    transport.close

with_toit_http_mediator logger/log.Logger mediator_id/string [block]:
  broker := http_broker.HttpBroker 0
  port_latch := monitor.Latch
  broker_task := task:: broker.start port_latch
  try:
    mediator_cli := MediatorCliHttp "localhost" port_latch.get --id="test/$mediator_id"
    mediator_service := MediatorServiceHttp logger "localhost" port_latch.get
    block.call logger mediator_id mediator_cli mediator_service
  finally:
    broker.close
    broker_task.cancel

