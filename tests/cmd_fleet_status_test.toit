// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import .utils

main args:
  with_fleet --args=args --count=3: | test_cli/TestCli fake_devices/List fleet_dir/string |
    run_test test_cli fake_devices fleet_dir

run_test test_cli/TestCli fake_devices/List fleet_dir/string:
  test_cli.run_gold "00_never_seen"
      "All three ids are shown as never seen"
      [
        "fleet",
        "status",
        "--include-never-seen"
      ]

  test_cli.run_gold "10_never_seen_empty"
      "No id is visible"
      [
        "fleet",
        "status",
      ]

  (fake_devices[0] as FakeDevice).report_state
  test_cli.run_gold "20_device0_is_online"
      "Device0 is online with 'now'"
      [
        "fleet",
        "status",
      ]

  fake_devices.do: it.report_state
  test_cli.run_gold "30_all_devices_are_online"
      "All devices have reported their state and are thus online"
      [
        "fleet",
        "status",
      ]

  (fake_devices[0] as FakeDevice).synchronize
  test_cli.run_gold "40_device0_checked_in"
      "Device0 fetched its goal and thus checked in"
      [
        "fleet",
        "status",
      ]

  test_cli.run_gold "50_unhealthy"
      "Device1 and Device2 are still unhealthy"
      [
        "fleet",
        "status",
        "--no-include-healthy",
      ]
