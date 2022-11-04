// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import ..artemis
import ..config
import ..cache
import .device_options_

create_app_commands config/Config cache/Cache -> List:
  install_cmd := cli.Command "install"
      --short_help="Install an app on a device."
      --options=device_options
      --rest=[
        cli.OptionString "app-name"
            --short_help="Name of the app to install."
            --required,
        cli.OptionString "application"
            --short_help="Program to install."
            --type="input-file"
            --required,
      ]
      --run=:: install_app config cache it

  uninstall_cmd := cli.Command "uninstall"
      --long_help="Uninstall an app from a device."
      --options=device_options
      --rest=[
        cli.OptionString "app-name"
            --short_help="Name of the app to uninstall.",
      ]
      --run=:: uninstall_app config cache it

  return [
    install_cmd,
    uninstall_cmd,
  ]

install_app config/Config cache/Cache parsed/cli.Parsed:
  app_name := parsed["app-name"]
  device_selector := parsed["device"]
  application_path :=parsed["application"]

  mediator := create_mediator config parsed
  artemis := Artemis mediator cache
  device_id := artemis.device_selector_to_id device_selector
  artemis.app_install --device_id=device_id --app_name=app_name --application_path=application_path
  artemis.close
  mediator.close

uninstall_app config/Config cache/Cache parsed/cli.Parsed:
  app_name := parsed["app-name"]
  device_selector := parsed["device"]

  mediator := create_mediator config parsed
  artemis := Artemis mediator cache
  device_id := artemis.device_selector_to_id device_selector
  artemis.app_uninstall --device_id=device_id --app_name=app_name
  artemis.close
  mediator.close
