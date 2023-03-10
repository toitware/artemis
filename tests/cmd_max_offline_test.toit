// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import .utils

main args:
  server_type := server_type_from_args args
  broker_type := broker_type_from_args args
  with_test_cli
      --artemis_type=server_type
      --broker_type=broker_type: | test_cli/TestCli device/Device |
    test_cli.run [
      "auth", "broker", "login",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    test_cli.run [
      "device",
      "set-max-offline",
      "--device-id", device.id,
       "3",
    ]

    with_timeout (Duration --s=10):
      counter := 0
      while true:
        if device.max_offline == (Duration --s=3): break
        sleep --ms=counter
        counter++

    test_cli.run [
      "device",
      "set-max-offline",
      "--device-id", device.id,
       "3m",
    ]

    with_timeout (Duration --s=10):
      counter := 0
      while true:
        if device.max_offline == (Duration --m=3): break
        sleep --ms=counter
        counter++
