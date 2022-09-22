// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe

import ..mediator
import ..mqtt.aws
import ..postgrest.supabase

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

get_mediator parsed/cli.Parsed -> Mediator:
  if parsed["supabase"]: return MediatorSupabase
  return create_aws_mediator
