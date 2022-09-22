// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log

import mqtt.transport as mqtt
import artemis.shared.mediator show MediatorCli
import artemis.service.mediator_service show MediatorService
import artemis.shared.mqtt.base show MediatorCliMqtt
import artemis.service.mqtt.synchronize show MediatorServiceMqtt
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
    else:
      throw "Unknown mediator $mediator_id"

with_mqtt_mediator logger/log.Logger mediator_id/string create_transport/Lambda [block]:
  transport/mqtt.Transport := create_transport.call
  mediator_cli/MediatorCli? := null
  mediator_service/MediatorService? := null
  try:
    mediator_cli = MediatorCliMqtt transport
    mediator_service = MediatorServiceMqtt logger --create_transport=create_transport

    block.call logger mediator_id mediator_cli mediator_service
  finally:
    if mediator_cli: mediator_cli.close
    transport.close
