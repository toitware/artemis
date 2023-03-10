// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli

import .broker_options_
import ..artemis
import ..cache
import ..config
import ..device_specification as device_specification
import ..ui

create_transient_command config/Config cache/Cache ui/Ui -> cli.Command:
  cmd := cli.Command "transient"
      --long_help="""
        Changes transient properties of the device.

        All changes done through this command are lost when the device
        loses power.
        """
      --options=broker_options + [
          cli.Option "device-id"
            --type="uuid"
            --short_name="d"
            --short_help="The device ID to use.",
      ]

  install_cmd := cli.Command "install"
      --short_help="Install an app on a device."
      --rest=[
        cli.OptionString "application-name"
            --short_help="Name of the application to install."
            --required,
        cli.OptionString "application"
            --short_help="Application to install."
            --type="input-file"
            --required,
        cli.Option "arguments"
            --short_help="Argument to pass to the application."
            --type="string"
            --multi,
      ]
      --run=:: install_app it config cache ui
  cmd.add install_cmd

  uninstall_cmd := cli.Command "uninstall"
      --long_help="Uninstall an application from a device."
      --rest=[
        cli.OptionString "application-name"
            --short_help="Name of the application to uninstall.",
      ]
      --run=:: uninstall_app it config cache ui
  cmd.add uninstall_cmd

  return cmd

get_device_id parsed/cli.Parsed config/Config ui/Ui -> string:
  device_id := parsed["device-id"]
  if not device_id: device_id = config.get CONFIG_DEVICE_DEFAULT_KEY
  if not device_id:
    ui.error "No device ID specified and no default device ID set."
    ui.abort
  return device_id

install_app parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  app_name := parsed["application-name"]
  application_path :=parsed["application"]
  arguments := parsed["arguments"]
  device_id := get_device_id parsed config ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.app_install
        --device_id=device_id
        --app_name=app_name
        --arguments=arguments
        --application_path=application_path
    ui.info "Request sent to broker. Application will be installed when device synchronizes."

uninstall_app parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  app_name := parsed["application-name"]
  device_id := get_device_id parsed config ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.app_uninstall --device_id=device_id --app_name=app_name
    ui.info "Request sent to broker. Application will be uninstalled when device synchronizes."
