// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.file
import encoding.ubjson
import encoding.base64
import uuid

import .broker_options_
import .device_options_

import ..artemis
import ..cache
import ..config
import ..device_specification
import ..jaguar as jaguar
import ..sdk
import ..server_config
import ..ui
import ..utils

import ...service.run.host show run_host

create_firmware_commands config/Config cache/Cache ui/Ui -> List:
  firmware_cmd := cli.Command "firmware"

  create_cmd := cli.Command "create"
      --short_help="Create firmware for flashing or updating."
      --options=broker_options + [
        cli.OptionString "output"
            --short_name="o"
            --type="file"
            --required
      ]
      --rest=[
        cli.Option "device-specification"
            --short_help="The device specification to use."
            --type="file"
            --required,
      ]
      --run=:: create_firmware it config cache ui
  firmware_cmd.add create_cmd

  update_cmd := cli.Command "update"
      --short_help="Update the firmware on a device."
      --options=device_options
      --rest=[
        cli.OptionString "firmware"
            --type="file"
            --short_help="Firmware envelope to install."
            --required,
      ]
      --run=:: update_firmware it config cache ui
  firmware_cmd.add update_cmd

  return [firmware_cmd]

create_firmware parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  specification_path := parsed["device-specification"]
  specification_json := read_json specification_path
  specification := DeviceSpecification.from_json specification_json
  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.customize_envelope
        --output_path=parsed["output"]
        --device_specification=specification
    ui.info "Firmware created."

update_firmware parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device_selector := parsed["device"]
  firmware_path := parsed["firmware"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    device_id := artemis.device_selector_to_id device_selector
    artemis.firmware_update --device_id=device_id --firmware_path=firmware_path --ui=ui

add_certificate_assets assets_path/string tmp/string certificates/Map sdk/Sdk -> none:
  // Add the certificates as distinct assets, so we can load them without
  // copying them into writable memory.
  certificates.do: | name/string value |
    write_blob_to_file "$tmp/$name" value
    sdk.run_assets_tool ["-e", assets_path, "add", name, "$tmp/$name"]
