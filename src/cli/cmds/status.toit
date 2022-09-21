// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import .device_options_

create_status_commands -> List:
  status_cmd := cli.Command "status"
      --short_help="Print the online status of the device."
      --options=device_options
      --run=:: show_status it

  watch_presence_cmd := cli.Command "watch-presence"
      --short_help="Watch for presence status changes of the device."
      --options=device_options
      --run=:: watch_presence it

  return [
    status_cmd,
    watch_presence_cmd
  ]

show_status parsed/cli.Parsed:
  client := get_client parsed
  client.print_status

watch_presence parsed/cli.Parsed:
  client := get_client parsed
  client.watch_presence
