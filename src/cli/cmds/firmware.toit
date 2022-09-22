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
  device_name := parsed["device"]
  firmware_path := parsed["firmware.bin"]

  mediator := get_mediator parsed
  artemis := Artemis mediator
  device_id := artemis.device_name_to_id device_name
  artemis.firmware_update --device_id=device_id --firmware_path=firmware_path
  artemis.close
  mediator.close
