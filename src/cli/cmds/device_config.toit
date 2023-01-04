// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import .device_options_
import ..artemis
import ..cache
import ..config
import ..ui

create_device_config_commands config/Config cache/Cache ui/Ui -> List:
  max_offline_cmd := cli.Command "set-max-offline"
      --short_help="Update the max-offline time of the device."
      --options=device_options
      --rest=[
        cli.OptionInt "max-offline"
            --short_help="The new max-offline time in seconds."
            --type="seconds"
            --required
      ]
      --run=:: set_max_offline it config cache ui

  return [ max_offline_cmd ]

set_max_offline parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device_selector := parsed["device"]
  max_offline := parsed["max-offline"]

  broker := create_broker_from_cli_args config parsed
  artemis := Artemis broker cache
  device_id := artemis.device_selector_to_id device_selector
  artemis.config_set_max_offline --device_id=device_id --max_offline_seconds=max_offline
  ui.info "Max offline time updated."
  artemis.close
  broker.close
