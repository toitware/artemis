// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.file
import encoding.ubjson
import encoding.base64
import uuid

import .provision
import .broker_options_
import .device_options_

import ..artemis
import ..config
import ..sdk
import ..broker

create_firmware_commands config/Config -> List:
  firmware_cmd := cli.Command "firmware"

  create_cmd := cli.Command "create"
      --short_help="Create firmware for flashing or updating."
      --options=broker_options + [
        cli.OptionString "output"
            --short_name="o"
            --type="file"
            --required
      ]
      --run=:: create_firmware config it

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
      --run=:: flash_firmware config it

  update_cmd := cli.Command "update"
      --short_help="Update the firmware on a device."
      --options=device_options
      --rest=[
        cli.OptionString "firmware"
            --type="file"
            --short_help="Firmware envelope to install."
            --required,
      ]
      --run=:: update_firmware config it

  firmware_cmd.add create_cmd
  firmware_cmd.add flash_cmd
  firmware_cmd.add update_cmd
  return [firmware_cmd]

create_firmware config/Config parsed/cli.Parsed -> none:
  output_path := parsed["output"]
  broker := get_broker config parsed["broker"]
  artemis_broker := get_broker config parsed["broker.artemis"]

  // TODO(kasper): It is pretty ugly that we have to copy
  // the supabase component to avoid messing with the
  // broker map.
  supabase := broker["supabase"].copy
  artemis_supabase := artemis_broker["supabase"].copy
  certificates := collect_certificates supabase
  (collect_certificates artemis_supabase).do: | key/string value |
    certificates[key] = value

  with_tmp_directory: | tmp/string |
    write_json_to_file "$tmp/broker.json" { "supabase" : supabase }
    write_json_to_file "$tmp/artemis.broker.json" { "supabase" : artemis_supabase }

    assets_path := "$tmp/artemis.assets"
    run_assets_tool ["-e", assets_path, "create"]
    run_assets_tool ["-e", assets_path, "add", "--format=tison", "broker", "$tmp/broker.json"]
    run_assets_tool ["-e", assets_path, "add", "--format=tison", "artemis.broker", "$tmp/artemis.broker.json"]
    add_certificate_assets assets_path tmp certificates

    snapshot_path := "$tmp/artemis.snapshot"
    run_toit_compile ["-w", snapshot_path, "src/service/run/device.toit"]

    // We compile the snapshot to a binary image, unless we're doing
    // source builds. This way, we do not leak the source code of the
    // artemis service.
    program_path := snapshot_path
    if IS_SOURCE_BUILD:
      cache_snapshot snapshot_path
    else:
      program_path = "$tmp/artemis.image"
      run_snapshot_to_image_tool ["-m32", "--binary", "-o", program_path, snapshot_path]

    // We have got the assets and the artemis code compiled. Now we
    // just need to generate the firmware envelope.
    run_firmware_tool [
        "-e", PATH_FIRMWARE_ENVELOPE_ESP32,
        "container", "install",
        "-o", output_path,
        "--assets", assets_path,
        "artemis", program_path,
    ]

    // TODO(kasper): Base the uuid on the actual firmware bits and the Toit SDK version used
    // to compile it. Maybe this can happen automatically somehow in tools/firmware?

    // Finally, make it unique. The system uuid will have to be used when compiling
    // code for the device in the future. This will prove that you know which versions
    // went into the firmware image.
    system_uuid ::= uuid.uuid5 "system.uuid" "$(random 1_000_000)-$Time.now-$Time.monotonic_us"
    run_firmware_tool ["-e", output_path, "property", "set", "uuid", system_uuid.stringify]

flash_firmware config/Config parsed/cli.Parsed:
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

  mediator := create_mediator config parsed
  artemis := Artemis mediator
  artemis.firmware_create
      --identity=identity
      --wifi=wifi
      --device_id=device_id
      --firmware_path=firmware_path
  artemis.close
  mediator.close

update_firmware config/Config parsed/cli.Parsed:
  device_selector := parsed["device"]
  firmware_path := parsed["firmware"]

  mediator := create_mediator config parsed
  artemis := Artemis mediator
  device_id := artemis.device_selector_to_id device_selector
  artemis.firmware_update --device_id=device_id --firmware_path=firmware_path
  artemis.close
  mediator.close
