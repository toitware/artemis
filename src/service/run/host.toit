// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe
import host.file
import system.assets
import encoding.json

import ..service show run_artemis
import ..monitoring show ping_setup

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

  // TODO(kasper): Move this elsewhere. Share with cli.
  broker_path := parsed["broker"]
  broker := json.decode (file.read_content broker_path)
  supabase := broker["supabase"]
  certificate_name := supabase["certificate"]
  // PEM certificates need to be zero terminated. Ugh.
  certificate := (file.read_content "config/certificates/$certificate_name") + #[0]
  supabase["certificate"] = certificate

  device := ping_setup (assets.decode identity)
  run_artemis device broker
