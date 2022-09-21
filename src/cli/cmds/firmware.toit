// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import crypto.sha256
import host.file
import uuid

import .device_options_

create_firmware_commands -> List:
  firmware_cmd := cli.Command "update"
      --short_help="Update the firmware on a device."
      --options=device_options
      --rest=[
        cli.OptionString "firmware.bin"
            --type="file"
            --short_help="Firmware to install."
            --required,
      ]
      --run=:: update_firmware it
  return [firmware_cmd]

update_firmware parsed/cli.Parsed:
  client := get_client parsed
  firmware_path := parsed["firmware.bin"]

  firmware_bin := file.read_content firmware_path
  sha := sha256.Sha256
  sha.add firmware_bin
  id/string := "$(uuid.Uuid sha.get[0..uuid.SIZE])"

  client.update_config: | config/Map |
    client.upload_firmware id firmware_bin
    config["firmware"] = id
    config
