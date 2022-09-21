// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import ..artemis
import .device_options_

create_app_commands -> List:
  install_cmd := cli.Command "install"
      --short_help="Install an app on a device."
      --options=device_options
      --rest=[
        cli.OptionString "app-name"
            --short_help="Name of the app to install."
            --required,
        cli.OptionString "snapshot"
            --short_help="Program to install."
            --type="input-file"
            --required,
      ]
      --run=:: install_app it

  uninstall_cmd := cli.Command "uninstall"
      --long_help="Uninstall an app from a device."
      --options=device_options
      --rest=[
        cli.OptionString "app-name"
            --short_help="Name of the app to uninstall.",
      ]
      --run=:: uninstall_app it

  return [
    install_cmd,
    uninstall_cmd,
  ]

install_app parsed/cli.Parsed:
  client := get_client parsed
  app_name := parsed["app-name"]
  snapshot_path := parsed["snapshot"]

  artemis := Artemis
  artemis.app_install client --app_name=app_name --snapshot_path=snapshot_path


uninstall_app parsed/cli.Parsed:
  client := get_client parsed
  app_name := parsed["app-name"]

  artemis := Artemis
  artemis.app_uninstall client --app_name=app_name
