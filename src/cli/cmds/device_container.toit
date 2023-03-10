// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli

import .broker_options_
import ..artemis
import ..cache
import ..config
import ..device_specification as device_specification
import ..ui

create_container_command config/Config cache/Cache ui/Ui -> cli.Command:
  cmd := cli.Command "container"
      --long_help="""
        ...

        All changes done through this command are lost when the device
        loses power.
        """
      --options=broker_options + [
        cli.Option "device-id"
            --short_name="d"
            --short_help="ID of the device."
            --type="uuid",
      ]

  install_cmd := cli.Command "install"
      --short_help="Install a container on a device."
      --rest=[
        cli.OptionString "name"
            --short_help="Name of the container to install."
            --required,
        cli.OptionString "path"
            --short_help="Path to source code or snapshot."
            --type="file"
            --required,
        cli.Option "arguments"
            --short_help="Argument to pass to the container."
            --type="string"
            --multi,
      ]
      --run=:: install_container it config cache ui
  cmd.add install_cmd

  uninstall_cmd := cli.Command "uninstall"
      --long_help="Uninstall a container from a device."
      --rest=[
        cli.OptionString "name"
            --short_help="Name of the container to uninstall.",
      ]
      --run=:: uninstall_container it config cache ui
  cmd.add uninstall_cmd

  return cmd

get_device_id parsed/cli.Parsed config/Config ui/Ui -> string:
  device_id := parsed["device-id"]
  if not device_id: device_id = config.get CONFIG_DEVICE_DEFAULT_KEY
  if not device_id:
    ui.error "No device ID specified and no default device ID set."
    ui.abort
  return device_id

install_container parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  container_name := parsed["name"]
  container_path := parsed["path"]
  arguments := parsed["arguments"]
  device_id := get_device_id parsed config ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.container_install
        --device_id=device_id
        --app_name=container_name
        --arguments=arguments
        --application_path=container_path
    ui.info "Request sent to broker. Container will be installed when device synchronizes."

uninstall_container parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  container_name := parsed["name"]
  device_id := get_device_id parsed config ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.container_uninstall --device_id=device_id --app_name=container_name
    ui.info "Request sent to broker. Container will be uninstalled when device synchronizes."
