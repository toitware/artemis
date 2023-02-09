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

  return cmd

set_max_offline parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device_id := parsed["device-id"]
  max_offline := parsed["max-offline"]

  if not device_id: device_id = config.get CONFIG_DEVICE_DEFAULT_KEY
  if not device_id:
    ui.error "No device ID specified and no default device ID set."
    ui.abort

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.config_set_max_offline --device_id=device_id --max_offline_seconds=max_offline
    ui.info "Max offline time updated."
