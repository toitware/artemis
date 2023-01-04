// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import .cache
import .config
import .ui

import .cmds.apps
import .cmds.config
import .cmds.firmware
import .cmds.status
import .cmds.device_config
import .cmds.provision
import .cmds.auth
import .cmds.org

// TODO:
//  - groups of devices
//  - device reject of configuration

main args:
  config := read_config
  cache := Cache --app_name="artemis"
  ui := ConsoleUi
  main args --config=config --cache=cache --ui=ui

main args --config/Config --cache/Cache --ui/Ui:
  root_cmd := cli.Command "root"
      --long_help="""
      A fleet management system for Toit devices.
      """

  // TODO(florian): the ui should be configurable by flags.
  // This might be easier, once the UI is integrated with the cli
  // package, as the package could then pass it to the commands after
  // it has parsed the UI flags.
  (create_app_commands config cache ui).do: root_cmd.add it
  (create_config_commands config cache ui).do: root_cmd.add it
  (create_firmware_commands config cache ui).do: root_cmd.add it
  (create_device_config_commands config cache ui).do: root_cmd.add it
  (create_status_commands config cache ui).do: root_cmd.add it
  (create_provision_commands config cache ui).do: root_cmd.add it
  (create_auth_commands config cache ui).do: root_cmd.add it
  (create_org_commands config cache ui).do: root_cmd.add it

  root_cmd.run args
