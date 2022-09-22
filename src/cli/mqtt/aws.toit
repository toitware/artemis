// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import .base
import ...shared.mqtt.aws

create_aws_mediator -> MediatorMqtt:
  network := net.open
  transport := aws_create_transport network
  return MediatorMqtt transport
