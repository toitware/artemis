// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import encoding.json
import expect show *

import .utils

main args:
  with_fleet --args=args --count=1: | test_cli/TestCli fake_devices/List fleet_dir/string |
    run_test test_cli fake_devices fleet_dir

run_test test_cli/TestCli fake_devices/List fleet_dir/string:
  device/FakeDevice := fake_devices[0]

  test_cli.run_gold "10-not-set"
      "No default device is set. -> Error."
      --expect_exit_1
      [
        "device", "default"
      ]

  test_cli.run_gold "20-set-default"
      "Set the default device"
      [
        "device", "default", "$device.alias_id"
      ]

  test_cli.run_gold "30-default-is-set"
      "The default device is set"
      [
        "device", "default"
      ]

  json_output := test_cli.run --json
      [
        "device", "default"
      ]
  expect_equals "$device.alias_id" json_output
