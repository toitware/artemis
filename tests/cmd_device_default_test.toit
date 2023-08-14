// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import encoding.json
import expect show *

import .utils

main args:
  with-fleet --args=args --count=1: | test-cli/TestCli fake-devices/List fleet-dir/string |
    run-test test-cli fake-devices fleet-dir

run-test test-cli/TestCli fake-devices/List fleet-dir/string:
  device/FakeDevice := fake-devices[0]

  test-cli.run-gold "10-not-set"
      "No default device is set. -> Error."
      --expect-exit-1
      [
        "device", "default"
      ]

  test-cli.run-gold "20-set-default"
      "Set the default device"
      [
        "device", "default", "$device.alias-id"
      ]

  test-cli.run-gold "30-default-is-set"
      "The default device is set"
      [
        "device", "default"
      ]

  json-output := test-cli.run --json
      [
        "device", "default"
      ]
  expect-equals "$device.alias-id" json-output
