// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import .broker_options_

import ..broker
import ..config
import ..broker
import ..brokers.mqtt.base
import ..brokers.postgrest.supabase

device_options -> List:
  return broker_options + [
    cli.OptionString "device"
        --short_name="d"
        --short_help="The device to use."
        --required
  ]

create_broker config/Config parsed/cli.Parsed -> BrokerCli:
  broker := get_broker_config config parsed["broker"]
  if broker.contains "supabase":
    return create_broker_cli_supabase broker["supabase"]
  if broker.contains "mqtt":
    return create_broker_cli_mqtt broker["mqtt"]
  throw "Unknown broker type"
