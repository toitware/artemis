// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import uuid

import .utils_
import ..artemis
import ..config
import ..cache
import ..device
import ..device_specification
import ..firmware
import ..fleet
import ..ui
import ..utils

create_fleet_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "fleet"
      --short_help="Manage multiple devices at the same time."
      --long_help="""
        The 'fleet' command allows you to manage multiple devices at the same
        time. It can be used to create firmware images, create identity files,
        upload firmware images, and update multiple devices at the same time.

        The 'update' command can be used intuitively to update multiple devices.

        The remaining commands are designed to be used in a workflow, where
        multiple devices are flashed with the same firmware image. Frequently,
        flash stations are not connected to the Internet, so the
        'create-identities' and 'create-firmware' commands are used to create
        the necessary files, which are then transferred to the flash station.

        A typical flashing workflow consists of:
        1. Create a firmware image using 'create-firmware'.
        1b. If the organization is already known, upload the firmware using
            'upload'.
        2. Create identity files using 'create-identities'.
        3. Transfer the firmware image and the identity files to the flash
           station.
        4. Flash the devices using 'device flash'.
        """

  init_cmd := cli.Command "init"
      --long_help="""
        Initialize the fleet directory.

        This command initializes the fleet directory, so it can be
        used by the other fleet commands.

        The directory can be specified using the '--fleet-root' option.

        The fleet will be in the given organization id. If no organization id
        is given, the default organization is used.
        """
      --options=[
        OptionUuid "organization-id"
            --short_help="The organization to use."
      ]
      --run=:: init it config cache ui
  cmd.add init_cmd

  create_firmware_cmd := cli.Command "create-firmware"
      --long_help="""
        Create a firmware image.

        The generated image can later be used to flash or update devices.
        When flashing, it needs to be combined with an identity file first. See
        'create-identities' for more information.

        Unless '--upload' is set to false (--no-upload), automatically uploads
        the firmware to the broker in the fleet's organization.

        By default uses the default specification file of the fleet.
        """
      --options=[
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the firmware.",
        cli.Option "output"
            --type="out-file"
            --short_name="o"
            --short_help="File to write the firmware to."
            --required,
        cli.Flag "upload"
            --short_help="Upload the firmware to the cloud."
            --default=true,
      ]
      --run=:: create_firmware it config cache ui
  cmd.add create_firmware_cmd

  create_identities_cmd := cli.Command "create-identities"
      --long_help="""
        Create a specified number of identity files.

        Identity files describe a device, containing their ID and organization.
        For each written identity file, a device is provisioned in the Toit
        cloud.

        Use 'flash-station flash' to flash a device with an identity file and a
        specification or firmware image.

        This command requires the broker to be configured.
        This command requires Internet access.
        """
      --options=[
        cli.Option "output-directory"
            --type="directory"
            --short_help="Directory to write the identity files to."
            --default=".",
      ]
      --aliases=[
        "provision",
      ]
      --rest=[
        cli.OptionInt "count"
            --short_help="Number of identity files to create."
            --required,
      ]
      --run=:: create_identities it config cache ui
  cmd.add create_identities_cmd

  upload_cmd := cli.Command "upload"
      --long_help="""
        Upload the given firmware to the broker.

        After this action the firmware is available to the fleet.
        Uploaded firmwares can be used for diff-based firmware updates.
        """
      --rest= [
        cli.Option "firmware"
            --type="afw file"
            --short_help="The firmware to upload."
            --required,
      ]
      --run=:: upload it config cache ui
  cmd.add upload_cmd

  update_cmd := cli.Command "update"
      --long_help="""
        Update the firmware of all devices in the fleet.

        Uses the 'default.json' specification.

        If diff-bases are given, then the given firmwares are uploaded to
        all organizations of the devices that are updated.

        If a device has no known state, patches for all base firmwares are
        created. If a device has reported its state, then only patches
        for the reported firmwares are created.

        The most common use case for diff bases is when the current
        state of the device is not yet known because it
        never connected to the broker. The corresponding identity might
        not even be used yet. In this case, one of the diff bases should be
        the firmware that will be (or was) used to flash the device.

        Note that diff-bases are only an optimization. Without them, the
        firmware update will still work, but will not be as efficient.
        """
      --options=[
        cli.Option "diff-base"
            --type="afw file"
            --short_help="The base firmware to use for diff-based updates."
            --multi,
      ]
      --run=:: update it config cache ui
  cmd.add update_cmd

  status_cmd := cli.Command "status"
      --long_help="""
        Show the status of the fleet.
        """
      --options=[
        cli.Flag "include-healthy"
            --short_help="Show healthy devices."
            --default=true,
        cli.Flag "include-never-seen"
            --short_help="Include devices that have never been seen."
            --default=false,
      ]
      --run=:: status it config cache ui
  cmd.add status_cmd

  add_device_cmd := cli.Command "add-device"
      --long_help="""
        Add an existing device to the fleet.

        This command adds an existing device to the fleet. The device must
        already be provisioned and be in the same organization as the fleet.

        Usually, this command is not needed. Devices are automatically added
        to the fleet when their identities are created.

        This command can be useful to migrate devices from one fleet to
        another, or to add devices that were created before fleets existed.
        """
      --options=[
        cli.Option "name"
            --short_help="The name of the device.",
        cli.Option "alias"
            --short_help="The alias of the device."
            --multi
            --split_commas,
      ]
      --rest=[
        OptionUuid "device-id"
            --short_help="The ID of the device to add."
            --required,
      ]
      --run=:: add_device it config cache ui
  cmd.add add_device_cmd

  return [cmd]

init parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  organization_id := parsed["organization-id"]

  if not organization_id:
    default_organization_id := default_organization_from_config config
    if not default_organization_id:
      ui.abort "No organization ID specified and no default organization ID set."

    organization_id = default_organization_id

  with_artemis parsed config cache ui: | artemis/Artemis |
    Fleet.init fleet_root artemis --organization_id=organization_id --ui=ui

create_firmware parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  specification_path := parsed["specification"]
  output := parsed["output"]
  should_upload := parsed["upload"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    if not specification_path:
      specification_path = fleet.default_specification_path
    fleet.create_firmware
        --specification_path=specification_path
        --output_path=output

create_identities parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  output_directory := parsed["output-directory"]
  count := parsed["count"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    created_files := fleet.create_identities count
        --output_directory=output_directory
    ui.info "Created $created_files.size identity file(s)."

update parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  diff_bases := parsed["diff-base"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    fleet.update --diff_bases=diff_bases

upload parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  firmware_path := parsed["firmware"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    fleet.upload --afw_path=firmware_path

status parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  include_healthy := parsed["include-healthy"]
  include_never_seen := parsed["include-never-seen"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    fleet.status --include_healthy=include_healthy --include_never_seen=include_never_seen

add_device parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  device_id := parsed["device-id"]
  name := parsed["name"]
  aliases := parsed["alias"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache

    with_artemis parsed config cache ui: | artemis/Artemis |
      broker := artemis.connected_broker
      devices := broker.get_devices --device_ids=[device_id]
      if devices.is_empty:
        ui.abort "Device $device_id not found."

      device/DeviceDetailed := devices[device_id]
      if device.organization_id != fleet.organization_id:
        ui.abort "Device $device_id is not in the same organization as the fleet."

      fleet.add_device --device_id=device.id --name=name --aliases=aliases
      ui.info "Added device $device_id to fleet."
