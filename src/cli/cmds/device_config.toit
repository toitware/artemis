// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import .device_options_

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

  client.update_config: | config/Map |
    print "$(%08d Time.monotonic_us): Setting max-offline to $(Duration --s=max_offline)"
    if max_offline > 0:
      config["max-offline"] = max_offline
    else:
      config.remove "max-offline"
    config
