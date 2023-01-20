// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli

import ..artemis
import ..config
import ..cache
import ..ui
import .broker_options_
import .device_options_

create_app_commands config/Config cache/Cache ui/Ui -> List:
  install_cmd := cli.Command "install"
      --short_help="Install an app on a device."
      --options=broker_options + device_options
      --rest=[
        cli.OptionString "app-name"
            --short_help="Name of the app to install."
            --required,
        cli.OptionString "application"
            --short_help="Program to install."
            --type="input-file"
            --required,
      ]
      --run=:: install_app it config cache ui

  uninstall_cmd := cli.Command "uninstall"
      --long_help="Uninstall an app from a device."
      --options=broker_options + device_options
      --rest=[
        cli.OptionString "app-name"
            --short_help="Name of the app to uninstall.",
      ]
      --run=:: uninstall_app it config cache ui

  return [
    install_cmd,
    uninstall_cmd,
  ]

install_app parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  app_name := parsed["app-name"]
  device_selector := parsed["device"]
  application_path :=parsed["application"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    device_id := artemis.device_selector_to_id device_selector
    artemis.app_install --device_id=device_id --app_name=app_name --application_path=application_path

uninstall_app parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  app_name := parsed["app-name"]
  device_selector := parsed["device"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    device_id := artemis.device_selector_to_id device_selector
    artemis.app_uninstall --device_id=device_id --app_name=app_name
