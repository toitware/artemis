// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate_roots
import cli
import uuid

import .broker_options_
import ..artemis
import ..config
import ..cache
import ..device_specification
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
        flash stations are not connected to the internet, so the
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
        Creates a firmware image.

        The generated image can later be used to flash or update devices.
        When flashing, it needs to be combined with an identity file first. See
        'create-identities' for more information.

        Unless '--upload' is set to false (--no-upload), automatically uploads
        the firmware to the broker. Without any 'organization-id', uses the
        default organization. Otherwise, uploads to the given organizations.
        """
      --options= broker_options + [
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
        Creates a specified number of identity files.

        Identity files describe a device, containing their ID and organization.
        For each written identity file, a device is provisioned in the Toit
        cloud.

        If an organization-id is given, then the device is registered with
        that organization. Otherwise, the device is registered with the
        default organization.

        Use 'device flash' to flash a device with an identity file and a
        specification or firmware image.

        This command requires the broker to be configured.
        This command requires internet access.
        """
      --options= broker_options + [
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
        Uploads the given firmware to the broker in the given organization.

        Uploaded firmwares can be used for diff-based firmware updates.

        If no organization is given, the default organization is used.
        """
      --options=broker_options + [
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
        Updates the firmware of multiple devices.

        This command takes either a firmware image or a specification file as
        input.
        """
      --options=broker_options + [
        cli.Option "specification"
            --type="file"
            --short_help="The specification to use.",
        cli.Option "firmware"
            --type="file"
            --short_help="The firmware to use.",
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
    specification := DeviceSpecification.parse specification_path
    artemis.customize_envelope
        --output_path=output
        --device_specification=specification

    organization_ids.do: | organization_id/string |
      artemis.upload_firmware output --organization_id=organization_id
      ui.info "Successfully uploaded firmware to organization $organization_id."

create_identities parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  output_directory := parsed["output-directory"]
  organization_id := parsed["organization-id"]
  count := parsed["count"]

  if not organization_id:
    organization_id = config.get CONFIG_ORGANIZATION_DEFAULT
    if not organization_id:
      ui.error "No organization ID specified and no default organization ID set."
      ui.abort

  count.repeat: | i/int |
    device_id := random_uuid_string

    output := "$output_directory/$(device_id).identity"

    with_artemis parsed config cache ui: | artemis/Artemis |
      artemis.provision
          --device_id=device_id
          --out_path=output
          --organization_id=organization_id
      ui.info "Created $output."

update parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  devices := parsed["device-id"]
  specification_path := parsed["specification"]
  firmware_path := parsed["firmware"]

  if not specification_path and not firmware_path:
    ui.error "No specification or firmware given."
    ui.abort

  if specification_path and firmware_path:
    ui.error "Both specification and firmware given."
    ui.abort

  with_artemis parsed config cache ui: | artemis/Artemis |
    with_tmp_directory: | tmp_dir/string |
      if specification_path:
        firmware_path = "$tmp_dir/firmware.envelope"
        specification := DeviceSpecification.parse specification_path
        artemis.customize_envelope
            --output_path=firmware_path
            --device_specification=specification

      devices.do: | device_id/string |
        artemis.update --device_id=device_id --envelope_path=firmware_path
        ui.info "Successfully updated device $device_id."

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
    organization_ids.do: | organization_id/string |
      artemis.upload_firmware envelope_path --organization_id=organization_id
      ui.info "Successfully uploaded firmware."
