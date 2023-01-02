// Copyright (C) 2022 Toitware ApS.

import .utils

main:
  with_test_cli: | test_cli/TestCli device/Device |
      test_cli.run [
        "set-max-offline",
        "--device=$device.id", "3"
      ]

      with_timeout --ms=2_000:
        counter := 0
        while true:
          if device.max_offline == (Duration --s=3): break
          sleep --ms=counter
          counter++
