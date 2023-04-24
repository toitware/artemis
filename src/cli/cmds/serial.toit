// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import host.file

import .utils_
import ..artemis
import ..cache
import ..config
import ..fleet
import ..sdk
import ..ui
import ..utils
import ...service.run.host show run_host

create_serial_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "serial"
      --short_help="Serial port commands."

  flash_cmd := cli.Command "flash"
      --long_help="""
        Flashes a device with the Artemis firmware.

        If no identity-file is provided, registers a new device as part
        of the organization-id in the Artemis cloud first.

        If a new device is registered, but no organization-id is provided,
        the device is registered with the default organization.

        The specification file contains the device specification. It includes
        the firmware version, installed applications, connection settings,
        etc. See 'specification-format' for more information.

        If an identity file is provided, the device may also be flashed with
        a firmware image instead of using a specification. In that case, the
        Artemis tool will not connect to the Internet.

        The 'chip' argument is used to select the chip to target when a device
        is flashed with a firmware image instead of a specification file.

        Unless '--no-default' is used, automatically makes this device the
        new default device.
        """
      --options=[
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the device.",
        cli.Option "firmware"
            --type="file"
            --short_help="The firmware image to flash.",
        cli.Option "identity"
            --type="file"
            --short_name="i"
            --short_help="The identity file to use.",
        cli.OptionEnum "chip" ["esp32", "esp32s2", "esp32s3", "esp32c3"]
            --default="esp32"
            --short_help="The chip to use.",
        cli.Option "organization-id"
            --type="uuid"
            --short_help="The organization to use.",
        cli.Flag "default"
            --default=true
            --short_help="Make this device the default device.",
        cli.Option "port"
            --short_name="p"
            --required,
        cli.Option "baud",
        OptionPatterns "partition"
            ["file:<name>=<path>", "empty:<name>=<size>"]
            --short_help="Add a custom partition to the device."
            --split_commas
            --multi,
        cli.Flag "simulate"
            --hidden
            --default=false,
      ]
      --run=:: flash it config cache ui
  cmd.add flash_cmd

  return [cmd]

flash parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet_root"]
  organization_id := parsed["organization-id"]
  specification_path := parsed["specification"]
  identity_path := parsed["identity"]
  firmware_path := parsed["firmware"]
  chip := parsed["chip"]
  port := parsed["port"]
  baud := parsed["baud"]
  simulate := parsed["simulate"]
  should_make_default := parsed["default"]

  if identity_path and organization_id:
    ui.error "Cannot specify both an identity file and an organization ID."
    ui.abort

  if firmware_path and not identity_path:
    ui.error "Cannot specify a firmware image without an identity file."
    ui.abort

  if firmware_path and specification_path:
    ui.error "Cannot specify both a firmware image and a specification file."
    ui.abort

  if not firmware_path and not specification_path:
    ui.error "Must specify either a firmware image or a specification file."
    ui.abort

  if not identity_path and not organization_id:
    organization_id = config.get CONFIG_ORGANIZATION_DEFAULT
    if not organization_id:
      ui.error "No organization ID specified and no default organization ID set."
      ui.abort

  partitions := []
  parsed["partition"].do: | partition/Map |
    type := partition.contains "file" ? "file" : "empty"
    description/string := partition[type]
    delimiter_index := description.index_of "="
    if delimiter_index < 0:
      ui.error "Partition of type '$type' is malformed: '$description'."
      ui.abort
    name := description[..delimiter_index]
    if name.is_empty:
      ui.error "Partition of type '$type' has no name."
      ui.abort
    if name.size > 15:
      ui.error "Partition of type '$type' has name with more than 15 characters."
      ui.abort
    value := description[delimiter_index + 1 ..]
    if type == "file":
      if not file.is_file value:
        ui.error "Partition $type:$name refers to invalid file."
        ui.error "No such file: $value."
        ui.abort
    else:
      size := int.parse value --on_error=:
        ui.error "Partition $type:$name has illegal size: '$it'"
        ui.abort
      if size <= 0:
        ui.error "Partition $type:$name has illegal size: $size"
        ui.abort
    partitions.add "$type:$description"

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache

    if not (identity_path and firmware_path):
      // Don't check for the existence of the organization if we are
      // flashing an image together with an identity. We might be
      // on a disconnected flash station.
      org := artemis.connected_artemis_server.get_organization organization_id
      if not org:
        ui.error "Organization $organization_id does not exist."
        ui.abort

    with_tmp_directory: | tmp_dir/string |
      new_provision := false
      if not identity_path:
        identity_files := fleet.create_identities 1
            --output_directory=tmp_dir
            --organization_id=organization_id
        identity_path = identity_files[0]
        new_provision = true

      identity := read_base64_ubjson identity_path
      // TODO(florian): Abstract away the identity format.
      organization_id = identity["artemis.device"]["organization_id"]
      device_id := identity["artemis.device"]["device_id"]

      if new_provision:
        ui.info "Successfully provisioned device $device_id."

      envelope_path/string := ?
      if specification_path:
        // Customize.
        specification := parse_device_specification_file specification_path --ui=ui
        chip = specification.chip or "esp32"
        envelope_path = "$tmp_dir/$(device_id).envelope"
        artemis.customize_envelope
            --output_path=envelope_path
            --device_specification=specification
        artemis.upload_firmware envelope_path --organization_id=organization_id
      else:
        envelope_path = firmware_path

      // Make unique for the given device.
      config_bytes := artemis.compute_device_specific_data
          --envelope_path=envelope_path
          --identity_path=identity_path

      config_path := "$tmp_dir/$(device_id).config"
      write_blob_to_file config_path config_bytes

      sdk_version := Sdk.get_sdk_version_from --envelope=envelope_path
      sdk := get_sdk sdk_version --cache=cache
      if not simulate:
        // Flash.
        sdk.flash
            --envelope_path=envelope_path
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
            --envelope_path=envelope_path
            --identity_path=identity_path
            --cache=cache
            --ui=ui

make_default_ device_id/string config/Config ui/Ui:
  config[CONFIG_DEVICE_DEFAULT_KEY] = device_id
  config.write
  ui.info "Default device set to $device_id"
