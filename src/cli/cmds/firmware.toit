// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import ..artemis
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

  artemis := Artemis
  artemis.firmware_update client --firmware_path=firmware_path
