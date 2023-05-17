// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import .cache
import .config
import .ui

import .cmds.auth
import .cmds.config
import .cmds.device
import .cmds.doc
import .cmds.fleet
import .cmds.org
import .cmds.pod
import .cmds.profile
import .cmds.sdk
import .cmds.serial

import ..shared.version

// TODO:
//  - groups of devices
//  - device reject of configuration

main args:
  config := read_config
  cache := Cache --app_name="artemis"
  // TODO(florian): adjust the UI level based on the flags.
  ui := ConsoleUi --level=Ui.NORMAL_LEVEL
  main args --config=config --cache=cache --ui=ui

main args --config/Config --cache/Cache --ui/Ui:
  // We don't want to add a `--version` option to the root command,
  // as that would make the option available to all subcommands.
  // Fundamentally, getting the version isn't really an option, but a
  // command. The `--version` here is just for convenience, since many
  // tools have it too.
  if args.size == 1 and args[0] == "--version":
    ui.result ARTEMIS_VERSION
    return

  root_cmd := cli.Command "root"
      --long_help="""
      A fleet management system for Toit devices.
      """
      --subcommands=[
        cli.Command "version"
            --long_help="Show the version of the Artemis tool."
            --run=:: ui.result ARTEMIS_VERSION,
      ]
      --options=[
        cli.Option "fleet-root"
            --type="directory"
            --short_help="Specify the fleet root."
            --default=".",
      ]

  // TODO(florian): the ui should be configurable by flags.
  // This might be easier, once the UI is integrated with the cli
  // package, as the package could then pass it to the commands after
  // it has parsed the UI flags.
  (create_config_commands config cache ui).do: root_cmd.add it
  (create_auth_commands config cache ui).do: root_cmd.add it
  (create_org_commands config cache ui).do: root_cmd.add it
  (create_profile_commands config cache ui).do: root_cmd.add it
  (create_sdk_commands config cache ui).do: root_cmd.add it
  (create_device_commands config cache ui).do: root_cmd.add it
  (create_fleet_commands config cache ui).do: root_cmd.add it
  (create_pod_commands config cache ui).do: root_cmd.add it
  (create_serial_commands config cache ui).do: root_cmd.add it
  (create_doc_commands config cache ui).do: root_cmd.add it

  root_cmd.run args
