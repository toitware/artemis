// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import .broker_options_

import ..broker
import ..config
import ...shared.mediator
import ...shared.mqtt.aws
import ...shared.postgrest.supabase

device_options -> List:
  return broker_options + [
    cli.OptionString "device"
        --short_name="d"
        --short_help="The device to use."
        --required
  ]

create_mediator config/Config parsed/cli.Parsed -> MediatorCli:
  broker := get_broker config parsed["broker"]
  if broker.contains "supabase":
    return create_mediator_cli_supabase broker
  return create_mediator_cli_aws

create_mediator --identity/Map -> MediatorCli:
  broker := identity["broker"]
  if broker.contains "supabase":
    return create_mediator_cli_supabase broker
  return create_mediator_cli_aws
