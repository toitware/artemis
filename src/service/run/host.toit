// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe
import host.file
import system.assets
import encoding.json

import ..service show run_artemis
import ..status show report_status_setup
import ...shared.config

main arguments:
  root_cmd := cli.Command "root"
      --options=[
        cli.OptionString "broker"
            --type="file"
            --default="config/brokers/toitware-testing.broker"
      ]
      --rest=[
        cli.OptionString "identity"
            --type="file"
            --required
      ]
      --run=:: run it
  root_cmd.run arguments

run parsed/cli.Parsed -> none:
  identity := file.read_content parsed["identity"]
  broker := read_broker_from_files parsed["broker"]
  device := report_status_setup (assets.decode identity)
  run_artemis device broker
