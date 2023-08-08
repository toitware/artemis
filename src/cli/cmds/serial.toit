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
import ..pod_registry
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
        Flashes a device with the firmware.

        The pod to flash on the device is found through the '$DEFAULT_GROUP' group
        or the specified '--group' in the current fleet.

        Unless '--no-default' is used, automatically makes this device the
        new default device.
        """
      --options=flash_options + [
        cli.Flag "default"
            --default=true
            --short_help="Make this device the default device.",
        cli.Option "group"
            --default=DEFAULT_GROUP
            --short_help="Add this device to a group.",
        cli.Option "local"
            --type="file"
            --short_help="A local pod file to flash.",
        cli.Flag "simulate"
            --hidden
            --default=false,
      ]
      --rest=[
        cli.Option "remote"
            --short_help="A remote pod reference; a UUID, name@tag, or name#revision.",
      ]
      --run=:: flash it config cache ui
  cmd.add flash_cmd

  write_ota_cmd := cli.Command "write-ota"
      --long_help="""
        Extracts a binary image that can be used for manual OTAs.
        """
      --options=[
        cli.Option "local"
            --type="file"
            --short_help="A local pod file to update to.",
        cli.Option "output"
            --short_name="o"
            --type="file"
            --short_help="The output file to write to.",
      ]
      --rest=[
        cli.Option "remote"
            --short_help="A remote pod reference; a UUID, name@tag, or name#revision.",
      ]
      --run=:: write_ota it config cache ui
  cmd.add write_ota_cmd


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
  port := parsed["port"]
  baud := parsed["baud"]
  simulate := parsed["simulate"]
  should_make_default := parsed["default"]
  group := parsed["group"]
  local := parsed["local"]
  remote := parsed["remote"]
  partitions := build_partitions_table_ parsed["partition"] --ui=ui

  if local and remote:
    ui.abort "Cannot specify both a local pod file and a remote pod reference."

  with_fleet parsed config cache ui: | fleet/Fleet |
    artemis := fleet.artemis_

    with_tmp_directory: | tmp_dir/string |
      identity_path := fleet.create_identity
          --group=group
          --output_directory=tmp_dir
      identity := read_base64_ubjson identity_path
      // TODO(florian): Abstract away the identity format.
      device_id := uuid.parse identity["artemis.device"]["device_id"]
      fleet_device := fleet.device device_id
      ui.info "Successfully provisioned device $fleet_device.name ($device_id)."

      pod/Pod := ?
      reference/PodReference := ?
      if local:
        pod = Pod.from_file local --artemis=artemis --ui=ui
        reference = PodReference --id=pod.id
      else:
        if remote:
          reference = PodReference.parse remote --allow_name_only --ui=ui
        else:
          reference = fleet.pod_reference_for_group group
        pod = fleet.download reference

      // Make unique for the given device.
      config_bytes := artemis.compute_device_specific_data
          --pod=pod
          --identity_path=identity_path

      config_path := "$tmp_dir/$(device_id).config"
      write_blob_to_file config_path config_bytes

      sdk := get_sdk pod.sdk_version --cache=cache
      if not simulate:
        ui.do --kind=Ui.VERBOSE: | printer/Printer|
          debug_line := "Flashing the device with pod $reference"
          if reference.id: debug_line += "."
          else: debug_line += " ($pod.id)."
          printer.emit debug_line
        // Flash.
        sdk.flash
            --envelope_path=pod.envelope_path
            --config_path=config_path
            --port=port
            --baud_rate=baud
            --partitions=partitions
            --chip=pod.chip
        if should_make_default: make_default_ device_id config ui
        info := "Successfully flashed device $fleet_device.name ($device_id"
        if group: info += " in group '$group'"
        info += ") with pod '$reference'"
        if reference.id: info += "."
        else: info += " ($pod.id)."
        ui.info info
      else:
        ui.info "Simulating flash."
        ui.info "Using the local Artemis service and not the one specified in the specification."
        old_default := config.get CONFIG_ARTEMIS_DEFAULT_KEY
        if should_make_default: make_default_ device_id config ui
        run_host
            --pod=pod
            --identity_path=identity_path
            --cache=cache

write_ota parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  output := parsed["output"]

  local := parsed["local"]
  remote := parsed["remote"]

  if local and remote:
    ui.abort "Cannot specify both a local pod file and a remote pod reference."

  with_fleet parsed config cache ui: | fleet/Fleet |
    artemis := fleet.artemis_

    with_tmp_directory: | tmp_dir/string |
      identity_path := fleet.create_identity
          --group=DEFAULT_GROUP
          --output_directory=tmp_dir
      identity := read_base64_ubjson identity_path
      // TODO(florian): Abstract away the identity format.
      device_id := uuid.parse identity["artemis.device"]["device_id"]
      fleet_device := fleet.device device_id
      ui.info "Successfully provisioned device $fleet_device.name ($device_id)."

      pod/Pod := ?
      reference/PodReference := ?
      if local:
        pod = Pod.from_file local --artemis=artemis --ui=ui
        reference = PodReference --id=pod.id
      else:
        if remote:
          reference = PodReference.parse remote --allow_name_only --ui=ui
        else:
          reference = fleet.pod_reference_for_group DEFAULT_GROUP
        pod = fleet.download reference

      // Make unique for the given device.
      config_bytes := artemis.compute_device_specific_data
          --pod=pod
          --identity_path=identity_path

      config_path := "$tmp_dir/$(device_id).config"
      write_blob_to_file config_path config_bytes

      sdk := get_sdk pod.sdk_version --cache=cache
      ui.do --kind=Ui.VERBOSE: | printer/Printer|
        debug_line := "Flashing the device with pod $reference"
        if reference.id: debug_line += "."
        else: debug_line += " ($pod.id)."
        printer.emit debug_line
      // Flash
      sdk.firmware_extract_ota
          --envelope_path=pod.envelope_path
          --device_specific_path=config_path
          --output_path=output

make_default_ device_id/uuid.Uuid config/Config ui/Ui:
  config[CONFIG_DEVICE_DEFAULT_KEY] = "$device_id"
  config.write
  ui.info "Default device set to $device_id."

flash --station/bool parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  if not station: throw "INVALID_ARGUMENT"
  identity_path := parsed["identity"]
  pod_path := parsed["pod"]
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
      // TODO(florian): don't print anything if ui is quiet/silent.
      sdk.flash
          --envelope_path=pod.envelope_path
          --config_path=config_path
          --port=port
          --baud_rate=baud
          --partitions=partitions
          --chip=pod.chip
      identity := read_base64_ubjson identity_path
      // TODO(florian): Abstract away the identity format.
      device_id := uuid.parse identity["artemis.device"]["device_id"]
      ui.info "Successfully flashed device $device_id with pod '$pod.name' ($pod.id)."
