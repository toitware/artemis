// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import .device_options_
import ..artemis
import ..config

create_device_config_commands config/Config -> List:
  max_offline_cmd := cli.Command "set-max-offline"
      --short_help="Update the max-offline time of the device."
      --options=device_options
      --rest=[
        cli.OptionInt "max-offline"
            --short_help="The new max-offline time in seconds."
            --type="seconds"
            --required
      ]
      --run=:: set_max_offline config it

  return [ max_offline_cmd ]

set_max_offline config/Config parsed/cli.Parsed:
  device_selector := parsed["device"]
  max_offline := parsed["max-offline"]

  mediator := create_mediator config parsed
  artemis := Artemis mediator
  device_id := artemis.device_selector_to_id device_selector
  artemis.config_set_max_offline --device_id=device_id --max_offline_seconds=max_offline
  artemis.close
  mediator.close
