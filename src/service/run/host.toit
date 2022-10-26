// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe
import host.file
import system.assets

import encoding.json
import encoding.ubjson
import encoding.base64
import encoding.tison

import ..broker show decode_broker
import ..service show run_artemis
import ..status show report_status_setup

import ...cli.sdk  // TODO(kasper): This is an annoying dependency.

import ..synchronize show OLD_BYTES_HACK

main arguments:
  root_cmd := cli.Command "root"
      --options=[
        cli.OptionString "firmware"
            --required,
        cli.OptionString "identity"
            --type="file"
            --required,
        cli.OptionString "old"
            --type="file",
      ]
      --run=:: run it
  root_cmd.run arguments

run parsed/cli.Parsed -> none:
  identity/Map? := null

  firmware := parsed["firmware"]
  initial_firmware := firmware.to_byte_array

  if parsed["old"]:
    OLD_BYTES_HACK = file.read_content parsed["old"]

  identity_raw := file.read_content parsed["identity"]
  identity = ubjson.decode (base64.decode identity_raw)
  identity["artemis.broker"] = tison.encode identity["artemis.broker"]
  identity["artemis.device"] = tison.encode identity["artemis.device"]
  identity["broker"] = tison.encode identity["broker"]

  device := report_status_setup identity
  broker := decode_broker "broker" identity
  run_artemis device broker --initial_firmware=initial_firmware
