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

  create_orig_cmd := cli.Command "create-orig"
      --short_help="Create firmware for flashing or updating."
      --options=broker_options + [
        cli.OptionString "output"
            --short_name="o"
            --type="file"
            --required
      ]
      --run=:: create_orig_firmware it config cache ui
  firmware_cmd.add create_orig_cmd

  flash_cmd := cli.Command "flash"
      --short_help="Flash the initial firmware on a device."
      --options=broker_options + [
        cli.OptionString "identity"
            --type="file"
            --required,
        cli.OptionString "wifi-ssid"
            --required,
        cli.OptionString "wifi-password",
        cli.OptionString "port"
            --short_name="p",
        cli.OptionString "baud",
        cli.Flag "simulate"
            --default=false,
      ]
      --rest=[
        cli.OptionString "firmware"
            --type="file"
            --short_help="Firmware envelope to flash."
            --required,
      ]
      --run=:: flash_firmware it config cache ui
  firmware_cmd.add flash_cmd

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

create_orig_firmware parsed/cli.Parsed config/Config cache/Cache ui/Ui -> none:
  output_path := parsed["output"]
  broker_config := get_server_from_config config parsed["broker"] CONFIG_BROKER_DEFAULT_KEY
  artemis_server_config := get_server_from_config config parsed["broker.artemis"] CONFIG_ARTEMIS_DEFAULT_KEY

  // TODO(florian): get the sdk correctly.
  sdk := Sdk

  deduplicated_certificates := {:}
  broker_json := server_config_to_service_json broker_config deduplicated_certificates
  artemis_broker_json := server_config_to_service_json artemis_server_config deduplicated_certificates


  with_tmp_directory: | tmp/string |
    write_json_to_file "$tmp/broker.json" broker_json
    write_json_to_file "$tmp/artemis.broker.json" artemis_broker_json

    assets_path := "$tmp/artemis.assets"
    sdk.run_assets_tool ["-e", assets_path, "create"]
    sdk.run_assets_tool ["-e", assets_path, "add", "--format=tison", "broker", "$tmp/broker.json"]
    sdk.run_assets_tool ["-e", assets_path, "add", "--format=tison", "artemis.broker", "$tmp/artemis.broker.json"]
    add_certificate_assets assets_path tmp deduplicated_certificates sdk

    snapshot_path := "$tmp/artemis.snapshot"
    sdk.run_toit_compile ["-w", snapshot_path, "src/service/run/device.toit"]

    // We compile the snapshot to a binary image, unless we're doing
    // source builds. This way, we do not leak the source code of the
    // artemis service.
    program_path := snapshot_path
    if sdk.is_source_build:
      jaguar.cache_snapshot snapshot_path
    else:
      program_path = "$tmp/artemis.image"
      sdk.run_snapshot_to_image_tool ["-m32", "--binary", "-o", program_path, snapshot_path]

    // We have got the assets and the artemis code compiled. Now we
    // just need to generate the firmware envelope.
    firmware_envelope := jaguar.resolve_firmware_envelope_path "esp32"
    sdk.run_firmware_tool [
        "-e", firmware_envelope,
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
    sdk.run_firmware_tool ["-e", output_path, "property", "set", "uuid", system_uuid.stringify]

flash_firmware parsed/cli.Parsed config/Config cache/Cache ui/Ui:
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

  // TODO(florian): get the SDK correctly.
  sdk := Sdk

  with_artemis parsed config cache ui: | artemis/Artemis |
    firmware := artemis.firmware_create
        --identity=identity
        --wifi=wifi
        --device_id=device_id
        --firmware_path=firmware_path
        --ui=ui

    if parsed["simulate"]:
      run_host
          --identity=identity
          --encoded=firmware.encoded
          --bits=firmware.content.bits
      return

    if not parsed["port"]:
      ui.error "No --port option given."
      ui.abort
    port/string := parsed["port"]
    baud/string? := parsed["baud"]

    // TODO(kasper): We should add an option to the flashing tool
    // that verifies that the hash of the output bits are the
    // expected ones -- or a flag that allows us to just pass
    // the bits in through a file.
    with_tmp_directory: | tmp/string |
      config_path := "$tmp/config.ubjson"
      write_blob_to_file config_path firmware.device_specific_data
      arguments := [
        "-e", firmware_path,
        "flash", "--port", port,
        "--config", config_path,
      ]
      if baud: arguments.add_all ["--baud", baud]
      sdk.run_firmware_tool arguments

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
