// Copyright (C) 2023 Toitware ApS.

import cli
import uart
import host.pipe

/**
A test device.

This part of the code runs in a spawned process and watches a real
  device through a serial port.

It reflects the forked part of the util's TestDevice.
*/

main args:
  cmd := cli.Command "root"
    --options=[
      cli.Option "port" --required,
    ]
    --run=::
      run it["port"]

  cmd.run args

run port-path/string:
  port := uart.HostPort port-path --baud-rate=115200
  pipe.stdout.out.write-from port.in
  pipe.stdout.close
