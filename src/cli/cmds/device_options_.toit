// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import .broker_options_

import ..config
import ..server_config
import ..brokers.broker
import ...shared.server_config

device_options -> List:
  return broker_options + [
    cli.OptionString "device"
        --short_name="d"
        --short_help="The device to use."
        --required
  ]

create_broker_from_cli_args config/Config parsed/cli.Parsed -> BrokerCli:
  server_config := get_server_from_config config parsed["broker"] CONFIG_BROKER_DEFAULT_KEY
  return BrokerCli server_config config
