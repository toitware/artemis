// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe

import ..client
import ..mqtt.aws
import ..postgrest.supabase

device_options -> List:
  hostname := null
  catch:
    hostname = pipe.backticks "hostname"

  return [
    cli.OptionString "device"
        --short_name="d"
        --short_help="The device to use."
        --default=hostname
        --required=(not hostname),
    cli.Flag "supabase"
        --short_name="S"
        --short_help="Use the Supabase database."
  ]

get_client parsed/cli.Parsed -> Client:
  client/Client? := null
  if parsed["supabase"]:
    client = ClientSupabase parsed["device"]
  else:
    client = ClientAws parsed["device"]

  return client
