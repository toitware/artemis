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
  client := get_client parsed
  max_offline := parsed["max-offline"]

  artemis := Artemis
  artemis.config_set_max_offline client --max_offline_seconds=max_offline
