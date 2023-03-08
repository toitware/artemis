// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import .utils

main args:
  with_test_cli --args=args --start_device: | test_cli/TestCli device/TestDevice |
    test_cli.run [
      "auth", "broker", "login",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    // Transient commands only work if we know the firmware the device
    // is actually running.
    device.wait_until_connected

    test_cli.run [
      "device",
      "transient",
      "--device-id", device.alias_id,
      "set-max-offline", "1"
    ]

    with_timeout (Duration --s=10):
      device.wait_for "synchronized {max-offline: 1s}"

    test_cli.run [
      "device",
      "transient",
      "--device-id", device.alias_id,
      "set-max-offline", "3m"
    ]

    with_timeout (Duration --s=10):
      device.wait_for "synchronized {max-offline: 3m0s}"
