// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import .utils

main args:
  with-fleet --args=args --count=3: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  fleet.run-gold "00_never_seen"
      "All three ids are shown as never seen"
      [
        "fleet",
        "status",
        "--include-never-seen"
      ]

  fleet.run-gold "10_never_seen_empty"
      "No id is visible"
      [
        "fleet",
        "status",
      ]

  fake-devices := fleet.devices.values

  (fake-devices[0] as FakeDevice).report-state
  fleet.run-gold "20_device0_is_online"
      "Device0 is online with 'now'"
      [
        "fleet",
        "status",
      ]

  fake-devices.do: it.report-state
  fleet.run-gold "30_all_devices_are_online"
      "All devices have reported their state and are thus online"
      [
        "fleet",
        "status",
      ]

  (fake-devices[0] as FakeDevice).synchronize
  fleet.run-gold "40_device0_checked_in"
      "Device0 fetched its goal and thus checked in"
      [
        "fleet",
        "status",
      ]

  fleet.run-gold "50_unhealthy"
      "Device1 and Device2 are still unhealthy"
      [
        "fleet",
        "status",
        "--no-include-healthy",
      ]
