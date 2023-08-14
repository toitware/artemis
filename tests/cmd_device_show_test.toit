// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import artemis.cli.fleet
import expect show *
import .utils

main args:
  with-fleet --count=3 --args=args: | test-cli/TestCli fake-devices/List fleet-dir/string |
    run-test test-cli fake-devices fleet-dir

run-test test-cli/TestCli fake-devices/List fleet-dir/string:
  fake-device1/FakeDevice := fake-devices[0]
  fake-device2/FakeDevice := fake-devices[1]
  fake-device3/FakeDevice := fake-devices[2]

  test-cli.run-gold "110-device-show"
      "Show the given device"
      [
        "device", "show", "-d", "$fake-device1.alias-id",
      ]

  test-cli.run-gold "111-device-show"
      "Show the given device"
      [
        "device", "show", "$fake-device1.alias-id",
      ]
