// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli

import .broker_options_
import ..artemis
import ..cache
import ..config
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

  max_offline_cmd := cli.Command "set-max-offline"
      --short_help="Update the max-offline time of the device."
      --rest=[
        cli.OptionInt "max-offline"
            --short_help="The new max-offline time in seconds."
            --type="seconds"
            --required
      ]
      --run=:: set_max_offline it config cache ui
  cmd.add max_offline_cmd

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

set_max_offline parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  max_offline := parsed["max-offline"]
  device_id := get_device_id parsed config ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.config_set_max_offline --device_id=device_id --max_offline_seconds=max_offline
    ui.info "Request sent to broker. Max offline time will be changed when device synchronizes."

install_app parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  app_name := parsed["application-name"]
  application_path :=parsed["application"]
  device_id := get_device_id parsed config ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.app_install --device_id=device_id --app_name=app_name --application_path=application_path
    ui.info "Request sent to broker. Application will be installed when device synchronizes."

uninstall_app parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  app_name := parsed["application-name"]
  device_id := get_device_id parsed config ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.app_uninstall --device_id=device_id --app_name=app_name
    ui.info "Request sent to broker. Application will be uninstalled when device synchronizes."
