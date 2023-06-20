// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import artemis.cli.fleet
import expect show *
import .utils

main args:
  with_fleet --count=3 --args=args: | test_cli/TestCli fake_devices/List fleet_dir/string |
    run_test test_cli fake_devices fleet_dir

run_test test_cli/TestCli fake_devices/List fleet_dir/string:
  fake_device1/FakeDevice := fake_devices[0]
  fake_device2/FakeDevice := fake_devices[1]
  fake_device3/FakeDevice := fake_devices[2]

  test_cli.run_gold "110-device-show"
      "Show the given device"
      [
        "device", "show", "-d", "$fake_device1.alias_id",
      ]

  test_cli.run_gold "111-device-show"
      "Show the given device"
      [
        "device", "show", "$fake_device1.alias_id",
      ]
