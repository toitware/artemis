// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import artemis.cli.fleet
import expect show *
import .utils

main args:
  with-fleet --count=3 --args=args: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  fake-devices := fleet.devices.values
  fake-device1/FakeDevice := fake-devices[0]
  fake-device2/FakeDevice := fake-devices[1]
  fake-device3/FakeDevice := fake-devices[2]

  fleet.run-gold "110-device-show"
      "Show the given device"
      [
        "device", "show", "-d", "$fake-device1.alias-id",
      ]

  fleet.run-gold "111-device-show"
      "Show the given device"
      [
        "device", "show", "$fake-device1.alias-id",
      ]
