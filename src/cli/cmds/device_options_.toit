// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import .broker_options_

import ..broker
import ..config
import ..broker
import ...shared.broker_config

device_options -> List:
  return broker_options + [
    cli.OptionString "device"
        --short_name="d"
        --short_help="The device to use."
        --required
  ]

create_broker_from_cli_args config/Config parsed/cli.Parsed -> BrokerCli:
  broker_config := get_broker_config config parsed["broker"]
  return create_broker broker_config
