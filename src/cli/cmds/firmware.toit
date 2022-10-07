// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.file
import encoding.ubjson
import encoding.base64

import .broker_options_
import .device_options_

import .provision show write_blob_to_file  // TODO(kasper): Move this elsewhere.
import ..artemis


create_firmware_commands -> List:
  firmware_cmd := cli.Command "firmware"

  flash_cmd := cli.Command "flash"
      --short_help="Flash the initial firmware on a device."
      --options=broker_options + [
        cli.OptionString "identity"
            --type="file"
            --required,
        cli.OptionString "wifi-ssid"
            --required,
        cli.OptionString "wifi-password",
        cli.OptionString "output"
            --short_name="o"
            --type="file"
      ]
      --rest=[
        cli.OptionString "firmware"
            --type="file"
            --short_help="Firmware envelope to flash."
            --required,
      ]
      --run=:: flash_firmware it

  update_cmd := cli.Command "update"
      --short_help="Update the firmware on a device."
      --options=device_options
      --rest=[
        cli.OptionString "firmware"
            --type="file"
            --short_help="Firmware envelope to install."
            --required,
      ]
      --run=:: update_firmware it

  firmware_cmd.add flash_cmd
  firmware_cmd.add update_cmd
  return [firmware_cmd]

flash_firmware parsed/cli.Parsed:
  firmware_path := parsed["firmware"]
  identity_path := parsed["identity"]

  wifi := {
    "wifi.ssid"     : parsed["wifi-ssid"],
    "wifi.password" : parsed["wifi-password"] or "",
  }

  // TODO(kasper): Can we share the whole identity management stuff?
  identity_raw := file.read_content identity_path
  identity := ubjson.decode (base64.decode identity_raw)
  device_id := identity["artemis.device"]["device_id"]
  output_path := parsed["output"] or "$(device_id).envelope"

  mediator := create_mediator parsed
  artemis := Artemis mediator
  artemis.firmware_create
      --identity=identity
      --wifi=wifi
      --device_id=device_id
      --firmware_path=firmware_path
      --output_path=output_path
  artemis.close
  mediator.close

  print "Created firmware => $output_path; now flash it onto your device"

update_firmware parsed/cli.Parsed:
  device_selector := parsed["device"]
  firmware_path := parsed["firmware"]

  mediator := create_mediator parsed
  artemis := Artemis mediator
  device_id := artemis.device_selector_to_id device_selector
  artemis.firmware_update --device_id=device_id --firmware_path=firmware_path
  artemis.close
  mediator.close
