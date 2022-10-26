// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import .config
import .cmds.apps
import .cmds.config
import .cmds.firmware
import .cmds.status
import .cmds.device_config
import .cmds.provision

// TODO:
//  - groups of devices
//  - device reject of configuration

main args:
  config := read_config

  root_cmd := cli.Command "root"
      --long_help="""
      A fleet management system for Toit devices.
      """

  (create_app_commands config).do: root_cmd.add it
  (create_config_commands config).do: root_cmd.add it
  (create_firmware_commands config).do: root_cmd.add it
  (create_device_config_commands config).do: root_cmd.add it
  (create_status_commands config).do: root_cmd.add it
  (create_provision_commands config).do: root_cmd.add it

  root_cmd.run args
