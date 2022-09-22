// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe

import ...shared.mediator
import ...shared.mqtt.aws
import ...shared.postgrest.supabase

device_options -> List:
  hostname := null
  catch:
    hostname = pipe.backticks "hostname"
    hostname = hostname.trim

  return [
    cli.OptionString "device"
        --short_name="d"
        --short_help="The device to use."
        --default=hostname
        --required=(not hostname),
    cli.Flag "supabase"
        --short_name="S"
        --short_help="Use Supabase."
  ]

create_mediator parsed/cli.Parsed -> MediatorCli:
  if parsed["supabase"]: return create_mediator_cli_supabase
  return create_mediator_cli_aws
