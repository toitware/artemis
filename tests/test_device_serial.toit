// Copyright (C) 2023 Toitware ApS.

import cli
import uart
import host.pipe
import writer show Writer

main args:
  cmd := cli.Command "root"
    --options=[
      cli.Option "port" --required,
    ]
    --run=::
      run it["port"]

  cmd.run args

run port_path/string:
  port := uart.HostPort port_path --baud_rate=115200
  writer := Writer pipe.stdout
  while chunk := port.read:
    writer.write chunk
  writer.close