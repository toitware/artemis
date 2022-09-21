// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import .device_options_
import ..artemis

create_device_config_commands -> List:
  max_offline_cmd := cli.Command "set-max-offline"
      --short_help="Update the max-offline time of the device."
      --options=device_options
      --rest=[
        cli.OptionInt "max-offline"
            --short_help="The new max-offline time in seconds."
            --type="seconds"
            --required
      ]
      --run=:: set_max_offline it

  return [ max_offline_cmd ]

set_max_offline parsed/cli.Parsed:
  device_id := parsed["device"]
  max_offline := parsed["max-offline"]

  mediator := get_mediator parsed
  artemis := Artemis mediator
  artemis.config_set_max_offline --device_id=device_id --max_offline_seconds=max_offline
  artemis.close
  mediator.close
