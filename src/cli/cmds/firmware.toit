// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli

import .utils_
import ..artemis
import ..config
import ..cache
import ..device_specification
import ..fleet
import ..ui

create_firmware_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "firmware"
      --aliases=["fw"]
      --long_help="""
        Create and manage firmware images.
        """

  create_firmware_cmd := cli.Command "build"
      --aliases=["create", "compile"]
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

  return [cmd]

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

upload parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]
  firmware_path := parsed["firmware"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    fleet.upload --afw_path=firmware_path
