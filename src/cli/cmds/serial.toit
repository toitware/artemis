// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import host.file
import uuid

import .utils_
import ..artemis
import ..cache
import ..config
import ..fleet
import ..pod
import ..sdk
import ..ui
import ..utils
import ...service.run.host show run_host

create_serial_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "serial"
      --short_help="Serial port commands."

  flash_options := [
    cli.Option "port"
        --short_name="p"
        --required,
    cli.Option "baud",
    OptionPatterns "partition"
        ["file:<name>=<path>", "empty:<name>=<size>"]
        --short_help="Add a custom partition to the device."
        --split_commas
        --multi,
  ]

  flash_cmd := cli.Command "flash"
      --long_help="""
        Flashes a device with the Artemis firmware.

        Uses the current fleet's specification file.

        Unless '--no-default' is used, automatically makes this device the
        new default device.
        """
      --options=flash_options + [
        cli.Flag "default"
            --default=true
            --short_help="Make this device the default device.",
        cli.Flag "simulate"
            --hidden
            --default=false,
      ]
      --run=:: flash it config cache ui
  cmd.add flash_cmd

  flash_station_cmd := cli.Command "flash-station"
      --long_help="""
        Commands for a flash station.

        Flash stations are typically used to flash devices in a factory.
        They don't have Internet access and must work with prebuilt
        identities and firmware images.

        Flash station commands don't need any valid fleet root.
        """
  cmd.add flash_station_cmd

  flash_station_flash_cmd := cli.Command "flash"
      --long_help="""
        Flashes a device on a flash station.

        Does not require Internet access.

        The 'chip' argument is used to select the chip to target.

        The 'port' argument is used to select the serial port to use.
        """
      --options=flash_options + [
        cli.Option "pod"
            --type="file"
            --short_help="The pod to flash."
            --required,
        cli.Option "identity"
            --type="file"
            --short_name="i"
            --short_help="The identity file to use."
            --required,
        cli.OptionEnum "chip" ["esp32", "esp32s2", "esp32s3", "esp32c3"]
            --default="esp32"
            --short_help="The chip to use.",
      ]
      --run=:: flash --station it config cache ui
  flash_station_cmd.add flash_station_flash_cmd

  return [cmd]

build_partitions_table_ partition_list/List --ui/Ui -> List:
  result := []
  partition_list.do: | partition_entry |
    if partition_entry is not Map:
      ui.abort "Partition entry must be a map."
    partition := partition_entry as Map
    type := partition.contains "file" ? "file" : "empty"
    description/string := partition[type]
    delimiter_index := description.index_of "="
    if delimiter_index < 0:
      ui.abort "Partition of type '$type' is malformed: '$description'."
    name := description[..delimiter_index]
    if name.is_empty:
      ui.abort "Partition of type '$type' has no name."
    if name.size > 15:
      ui.abort "Partition of type '$type' has name with more than 15 characters."
    value := description[delimiter_index + 1 ..]
    if type == "file":
      if not file.is_file value:
        ui.error "Partition $type:$name refers to invalid file."
        ui.error "No such file: $value."
        ui.abort
    else:
      size := int.parse value --on_error=:
        ui.abort "Partition $type:$name has illegal size: '$it'."
      if size <= 0:
        ui.abort "Partition $type:$name has illegal size: $size."
    result.add "$type:$description"
  return result

flash parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet_root"]
  port := parsed["port"]
  baud := parsed["baud"]
  simulate := parsed["simulate"]
  should_make_default := parsed["default"]
  partitions := build_partitions_table_ parsed["partition"] --ui=ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache

    with_tmp_directory: | tmp_dir/string |
      identity_files := fleet.create_identities 1 --output_directory=tmp_dir
      identity_path := identity_files[0]
      identity := read_base64_ubjson identity_path
      // TODO(florian): Abstract away the identity format.
      device_id := uuid.parse identity["artemis.device"]["device_id"]
      ui.info "Successfully provisioned device $device_id."

      specification := fleet.read_specification_for device_id
      chip := specification.chip or "esp32"
      pod := Pod.from_specification --specification=specification --artemis=artemis
      fleet.upload --pod=pod

      // Make unique for the given device.
      config_bytes := artemis.compute_device_specific_data
          --pod=pod
          --identity_path=identity_path

      config_path := "$tmp_dir/$(device_id).config"
      write_blob_to_file config_path config_bytes

      sdk := get_sdk pod.sdk_version --cache=cache
      if not simulate:
        // Flash.
        sdk.flash
            --envelope_path=pod.envelope_path
            --config_path=config_path
            --port=port
            --baud_rate=baud
            --partitions=partitions
            --chip=chip
        if should_make_default: make_default_ device_id config ui
      else:
        ui.info "Simulating flash."
        ui.info "Using the local Artemis service and not the one specified in the specification."
        old_default := config.get CONFIG_ARTEMIS_DEFAULT_KEY
        if should_make_default: make_default_ device_id config ui
        run_host
            --pod=pod
            --identity_path=identity_path
            --cache=cache

make_default_ device_id/uuid.Uuid config/Config ui/Ui:
  config[CONFIG_DEVICE_DEFAULT_KEY] = "$device_id"
  config.write
  ui.info "Default device set to $device_id."

flash --station/bool parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  if not station: throw "INVALID_ARGUMENT"
  identity_path := parsed["identity"]
  pod_path := parsed["pod"]
  chip := parsed["chip"]
  port := parsed["port"]
  baud := parsed["baud"]
  partitions := build_partitions_table_ parsed["partition"] --ui=ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    pod := Pod.parse pod_path --tmp_directory=artemis.tmp_directory --ui=ui
    with_tmp_directory: | tmp_dir/string |
      // Make unique for the given device.
      config_bytes := artemis.compute_device_specific_data
          --pod=pod
          --identity_path=identity_path

      config_path := "$tmp_dir/config"
      write_blob_to_file config_path config_bytes

      // Flash.
      sdk := get_sdk pod.sdk_version --cache=cache
      sdk.flash
          --envelope_path=pod.envelope_path
          --config_path=config_path
          --port=port
          --baud_rate=baud
          --partitions=partitions
          --chip=chip
