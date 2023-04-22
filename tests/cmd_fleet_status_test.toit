// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.cli.utils show read_base64_ubjson
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

with_fleet --args/List --count/int [block]:
  with_test_cli --args=args: | test_cli/TestCli |
    with_tmp_directory: | fleet_dir |
      test_cli.run [
        "auth", "login",
        "--email", TEST_EXAMPLE_COM_EMAIL,
        "--password", TEST_EXAMPLE_COM_PASSWORD,
      ]

      test_cli.run [
        "auth", "login",
        "--broker",
        "--email", TEST_EXAMPLE_COM_EMAIL,
        "--password", TEST_EXAMPLE_COM_PASSWORD,
      ]

      test_cli.run [
        "fleet",
        "--fleet-root", fleet_dir,
        "init",
      ]

      identity_dir := "$fleet_dir/identities"
      directory.mkdir --recursive identity_dir
      test_cli.run [
        "fleet",
        "--fleet-root", fleet_dir,
        "create-identities",
        "--organization-id", TEST_ORGANIZATION_UUID,
        "--output-directory", identity_dir,
        "$count",
      ]

      devices := json.decode (file.read_content "$fleet_dir/devices.json")
      ids := devices.keys
      expect_equals count ids.size

      fake_devices := []
      ids.do: | id/string |
        id_file := "$identity_dir/$(id).identity"
        expect (file.is_file id_file)
        content := read_base64_ubjson id_file
        fake_device := test_cli.start_fake_device --identity=content
        test_cli.replacements[id] = "-={| UUID-FOR-FAKE-DEVICE $(%05d fake_devices.size) |}=-"
        fake_devices.add fake_device

      block.call test_cli fake_devices fleet_dir

run_test test_cli/TestCli fake_devices/List fleet_dir/string:
  output := test_cli.run [
    "fleet",
    "--fleet-root", fleet_dir,
    "status",
    "--include-never-seen"
  ]
  expect_equals
      """
      ┌──────────────────────────────────────┬──────┬──────────┬──────────┬─────────────────┬───────────┬─────────┐
      │ Device ID                              Name   Outdated   Modified   Missed Checkins   Last Seen   Aliases │
      ├──────────────────────────────────────┼──────┼──────────┼──────────┼─────────────────┼───────────┼─────────┤
      │ -={| UUID-FOR-FAKE-DEVICE 00000 |}=-          ✗                     ?                 never               │
      │ -={| UUID-FOR-FAKE-DEVICE 00001 |}=-          ✗                     ?                 never               │
      │ -={| UUID-FOR-FAKE-DEVICE 00002 |}=-          ✗                     ?                 never               │
      └──────────────────────────────────────┴──────┴──────────┴──────────┴─────────────────┴───────────┴─────────┘
      """
      output

  output = test_cli.run [
    "fleet",
    "--fleet-root", fleet_dir,
    "status",
  ]
  expect_equals
      """
      ┌───────────┬──────┬──────────┬──────────┬─────────────────┬───────────┬─────────┐
      │ Device ID   Name   Outdated   Modified   Missed Checkins   Last Seen   Aliases │
      ├───────────┼──────┼──────────┼──────────┼─────────────────┼───────────┼─────────┤
      └───────────┴──────┴──────────┴──────────┴─────────────────┴───────────┴─────────┘
      """
      output

  (fake_devices[0] as FakeDevice).report_state
  output = test_cli.run [
    "fleet",
    "--fleet-root", fleet_dir,
    "status",
  ]
  expect_equals
      """
      ┌──────────────────────────────────────┬──────┬──────────┬──────────┬─────────────────┬───────────┬─────────┐
      │ Device ID                              Name   Outdated   Modified   Missed Checkins   Last Seen   Aliases │
      ├──────────────────────────────────────┼──────┼──────────┼──────────┼─────────────────┼───────────┼─────────┤
      │ -={| UUID-FOR-FAKE-DEVICE 00000 |}=-                                ?                 now                 │
      └──────────────────────────────────────┴──────┴──────────┴──────────┴─────────────────┴───────────┴─────────┘
      """
      output

  fake_devices.do: it.report_state
  output = test_cli.run [
    "fleet",
    "--fleet-root", fleet_dir,
    "status",
  ]
  expect_equals
      """
      ┌──────────────────────────────────────┬──────┬──────────┬──────────┬─────────────────┬───────────┬─────────┐
      │ Device ID                              Name   Outdated   Modified   Missed Checkins   Last Seen   Aliases │
      ├──────────────────────────────────────┼──────┼──────────┼──────────┼─────────────────┼───────────┼─────────┤
      │ -={| UUID-FOR-FAKE-DEVICE 00000 |}=-                                ?                 now                 │
      │ -={| UUID-FOR-FAKE-DEVICE 00001 |}=-                                ?                 now                 │
      │ -={| UUID-FOR-FAKE-DEVICE 00002 |}=-                                ?                 now                 │
      └──────────────────────────────────────┴──────┴──────────┴──────────┴─────────────────┴───────────┴─────────┘
      """
      output

  (fake_devices[0] as FakeDevice).synchronize
  output = test_cli.run [
    "fleet",
    "--fleet-root", fleet_dir,
    "status",
  ]
  expect_equals
      """
      ┌──────────────────────────────────────┬──────┬──────────┬──────────┬─────────────────┬───────────┬─────────┐
      │ Device ID                              Name   Outdated   Modified   Missed Checkins   Last Seen   Aliases │
      ├──────────────────────────────────────┼──────┼──────────┼──────────┼─────────────────┼───────────┼─────────┤
      │ -={| UUID-FOR-FAKE-DEVICE 00000 |}=-                                                  now                 │
      │ -={| UUID-FOR-FAKE-DEVICE 00001 |}=-                                ?                 now                 │
      │ -={| UUID-FOR-FAKE-DEVICE 00002 |}=-                                ?                 now                 │
      └──────────────────────────────────────┴──────┴──────────┴──────────┴─────────────────┴───────────┴─────────┘
      """
      output

  output = test_cli.run [
    "fleet",
    "--fleet-root", fleet_dir,
    "status",
    "--unhealthy",
  ]
  expect_equals
      """
      ┌──────────────────────────────────────┬──────┬──────────┬──────────┬─────────────────┬───────────┬─────────┐
      │ Device ID                              Name   Outdated   Modified   Missed Checkins   Last Seen   Aliases │
      ├──────────────────────────────────────┼──────┼──────────┼──────────┼─────────────────┼───────────┼─────────┤
      │ -={| UUID-FOR-FAKE-DEVICE 00001 |}=-                                ?                 now                 │
      │ -={| UUID-FOR-FAKE-DEVICE 00002 |}=-                                ?                 now                 │
      └──────────────────────────────────────┴──────┴──────────┴──────────┴─────────────────┴───────────┴─────────┘
      """
      output
