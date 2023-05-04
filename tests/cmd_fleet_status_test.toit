// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.shared.server_config show ServerConfig
import encoding.json
import host.directory
import host.file
import expect show *
import .utils

main args:
  with_fleet --args=args --count=3: | test_cli/TestCli fake_devices/List fleet_dir/string |
    run_test test_cli fake_devices fleet_dir

run_test test_cli/TestCli fake_devices/List fleet_dir/string:
  test_cli.run_gold "00_never_seen"
      "All three ids are shown as never seen"
      [
        "fleet",
        "--fleet-root", fleet_dir,
        "status",
        "--include-never-seen"
      ]

  test_cli.run_gold "10_never_seen_empty"
      "No id is visible"
      [
        "fleet",
        "--fleet-root", fleet_dir,
        "status",
      ]

  (fake_devices[0] as FakeDevice).report_state
  test_cli.run_gold "20_device0_is_online"
      "Device0 is online with 'now'"
      [
        "fleet",
        "--fleet-root", fleet_dir,
        "status",
      ]

  fake_devices.do: it.report_state
  test_cli.run_gold "30_all_devices_are_online"
      "All devices have reported their state and are thus online"
      [
        "fleet",
        "--fleet-root", fleet_dir,
        "status",
      ]

  (fake_devices[0] as FakeDevice).synchronize
  test_cli.run_gold "40_device0_checked_in"
      "Device0 fetched its goal and thus checked in"
      [
        "fleet",
        "--fleet-root", fleet_dir,
        "status",
      ]

  test_cli.run_gold "50_unhealthy"
      "Device1 and Device2 are still unhealthy"
      [
        "fleet",
        "--fleet-root", fleet_dir,
        "status",
        "--no-include-healthy",
      ]
