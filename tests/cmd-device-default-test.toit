// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import encoding.json
import expect show *

import .utils

main args:
  with-fleet --args=args --count=1: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  device/FakeDevice := fleet.devices.values[0]

  fleet.run-gold "10-not-set"
      "No default device is set. -> Error."
      --expect-exit-1
      [
        "device", "default"
      ]

  fleet.run-gold "20-set-default"
      "Set the default device"
      [
        "device", "default", "$device.id"
      ]

  fleet.run-gold "30-default-is-set"
      "The default device is set"
      [
        "device", "default"
      ]

  json-output := fleet.run --json
      [
        "device", "default"
      ]
  expect-equals "$device.id" json-output
