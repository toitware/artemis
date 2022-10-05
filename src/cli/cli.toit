// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import .cmds.apps
import .cmds.firmware
import .cmds.status
import .cmds.device_config
import .cmds.provision

// TODO:
//  - groups of devices
//  - device reject of configuration

main args:
  root_cmd := cli.Command "root"
      --long_help="""
      A fleet management system for Toit devices.
      """

  create_app_commands.do: root_cmd.add it
  create_firmware_commands.do: root_cmd.add it
  create_device_config_commands.do: root_cmd.add it
  create_status_commands.do: root_cmd.add it
  create_provision_commands.do: root_cmd.add it

  root_cmd.run args
