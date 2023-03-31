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

  create_firmware_cmd := cli.Command "create-firmware"
      --long_help="""
        Create a firmware image.

        The generated image can later be used to flash or update devices.
        When flashing, it needs to be combined with an identity file first. See
        'create-identities' for more information.

        Unless '--upload' is set to false (--no-upload), automatically uploads
        the firmware to the broker. Without any 'organization-id', uses the
        default organization. Otherwise, uploads to the given organizations.
        """
      --options=[
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the firmware."
            --required,
        cli.Option "output"
            --type="out-file"
            --short_name="o"
            --short_help="File to write the firmware to."
            --required,
        cli.Option "organization-id"
            --type="uuid"
            --short_help="The organization to upload the firmware to."
            --split_commas
            --multi,
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

        If an organization-id is given, then the device is registered with
        that organization. Otherwise, the device is registered with the
        default organization.

        Use 'device flash' to flash a device with an identity file and a
        specification or firmware image.

        This command requires the broker to be configured.
        This command requires Internet access.
        """
      --options=[
        cli.Option "organization-id"
            --type="uuid"
            --short_help="The organization to use.",
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
        Upload the given firmware to the broker in the given organization.

        Uploaded firmwares can be used for diff-based firmware updates.

        If no organization is given, the default organization is used.
        """
      --options=[
        cli.Option "organization-id"
            --type="uuid"
            --short_help="The organization to use."
            --split_commas
            --multi,
      ]
      --rest= [
        cli.Option "firmware"
            --type="file"
            --short_help="The firmware to upload."
            --required,
      ]
      --run=:: upload it config cache ui
  cmd.add upload_cmd

  update_cmd := cli.Command "update"
      --long_help="""
        Update the firmware of multiple devices.

        This command takes either a firmware image or a specification file as
        input.

        If diff-bases are given, then the given firmwares are uploaded to
        all organizations of the devices that are updated.

        If a device has no known state, patches for all base firmwares are
        created. If a device has reported its state, then only patches
        for the reported firmwares are created.

        There are two cases that make diff bases necessary:
        1. The current state of the device is not yet known because it
          never connected to the broker. The corresponding identity might
          not even be used yet. In this case, one of the diff bases should be
          the firmware that will be (or was) used to flash the device.
        2. The device has connected and the current firmware is known. However,
          when the firmware was created, it was not yet uploaded. It is generally
          recommended to upload the firmware immediately after creating it, but
          when that's not possible (for example, because the organization is
          not known yet), then explicitly specifying the diff base is
          necessary.

        Note that diff-bases are only an optimization. Without them, the
        firmware update will still work, but will not be as efficient.
        """
      --options=[
        cli.Option "specification"
            --type="file"
            --short_help="The specification to use.",
        cli.Option "firmware"
            --type="file"
            --short_help="The firmware to use.",
        cli.Option "diff-base"
            --type="file"
            --short_help="The base firmware to use for diff-based updates."
            --multi,
      ]
      --rest= [
        cli.Option "device-id"
            --type="uuid"
            --short_help="The ID of the device."
            --multi
            --required,
      ]
      --run=:: update it config cache ui
  cmd.add update_cmd

  return [cmd]

create_firmware parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  specification_path := parsed["specification"]
  output := parsed["output"]
  organization_ids := parsed["organization-id"]
  should_upload := parsed["upload"]

  if should_upload and organization_ids.is_empty:
    default_organization_id := config.get CONFIG_ORGANIZATION_DEFAULT
    if not default_organization_id:
      ui.error "No organization ID specified and no default organization ID set."
      ui.abort

    organization_ids = [default_organization_id]

  if not should_upload and not organization_ids.is_empty:
    ui.error "Cannot specify organization IDs when not uploading."
    ui.abort

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet artemis --ui=ui --cache=cache
    fleet.create_firmware
        --specification_path=specification_path
        --output_path=output
        --organization_ids=organization_ids

create_identities parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  output_directory := parsed["output-directory"]
  organization_id := parsed["organization-id"]
  count := parsed["count"]

  if not organization_id:
    organization_id = config.get CONFIG_ORGANIZATION_DEFAULT
    if not organization_id:
      ui.error "No organization ID specified and no default organization ID set."
      ui.abort

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet artemis --ui=ui --cache=cache
    fleet.create_identities count
        --output_directory=output_directory
        --organization_id=organization_id

update parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  devices := parsed["device-id"]
  specification_path := parsed["specification"]
  firmware_path := parsed["firmware"]
  diff_bases := parsed["diff-base"]

  if not specification_path and not firmware_path:
    ui.error "No specification or firmware given."
    ui.abort

  if specification_path and firmware_path:
    ui.error "Both specification and firmware given."
    ui.abort


  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet artemis --ui=ui --cache=cache
    fleet.update devices
        --specification_path=specification_path
        --firmware_path=firmware_path
        --diff_bases=diff_bases

upload parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  envelope_path := parsed["firmware"]
  organization_ids := parsed["organization-id"]

  if organization_ids.is_empty:
    organization_id := config.get CONFIG_ORGANIZATION_DEFAULT
    if not organization_id:
      ui.error "No organization ID specified and no default organization ID set."
      ui.abort
    organization_ids = [organization_id]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet artemis --ui=ui --cache=cache
    fleet.upload envelope_path --to=organization_ids
