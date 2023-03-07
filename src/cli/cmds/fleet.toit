// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate_roots
import cli

import .broker_options_
import ..config
import ..cache
import ..ui

create_fleet_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "fleet"
      --short_help="Manage multiple devices at the same time."

  create_firmware_cmd := cli.Command "create-firmware"
      --long_help="""
        Creates a firmware image.

        The generated image can later be used to flash or update devices.
        When flashing, it needs to be combined with an identity file first. See
        'create-identities' for more information.
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
      ]
      --run=:: create_firmware it config cache ui
  cmd.add create_firmware_cmd

  create_identities_cmd := cli.Command "create-identities"
      --long_help="""
        Creates a certain number of identity files.

        Identity files describe a device, containing their ID and organization.
        For each written identity file, a device is provisioned in the Toit
        cloud.

        Use 'device flash' to flash a device with an identity file and a
        specification or firmware image.
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
      --rest=[
        cli.OptionInt "count"
            --short_help="Number of identity files to create."
            --required,
      ]
      --run=:: create_identities it config cache ui
  cmd.add create_identities_cmd

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
  throw "Unimplemented"

create_identities parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  throw "Unimplemented"

update parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  throw "Unimplemented"
