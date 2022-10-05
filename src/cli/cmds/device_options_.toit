// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe

import .broker_options_

import ...shared.mediator
import ...shared.mqtt.aws
import ...shared.postgrest.supabase

device_options -> List:
  hostname := null
  catch:
    hostname = pipe.backticks "hostname"
    hostname = hostname.trim

  return broker_options + [
    cli.OptionString "device"
        --short_name="d"
        --short_help="The device to use."
        --default=hostname
        --required=(not hostname),
  ]

create_mediator parsed/cli.Parsed -> MediatorCli:
  broker := read_broker "broker" parsed
  if broker.contains "supabase":
    return create_mediator_cli_supabase broker
  return create_mediator_cli_aws
