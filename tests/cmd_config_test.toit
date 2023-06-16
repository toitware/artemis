// Copyright (C) 2022 Toitware ApS.

import artemis.shared.server_config show ServerConfigHttp
import expect show *
import .utils

main args:
  with_fleet --args=args --count=1: | test_cli/TestCli fake_devices/List fleet_dir/string |
    run_test test_cli fake_devices fleet_dir

run_test test_cli/TestCli fake_devices/List fleet_dir/string:
  json_config := test_cli.run --json [
    "config", "show"
  ]
  expect_equals "$test_cli.tmp_dir/config" json_config["path"]
  expect_equals "test-broker" json_config["default-broker"]
  servers := json_config["servers"]
  expect (servers.contains "test-broker")
  expect (servers.contains "test-artemis-server")

  broker_config := servers["test-broker"]
  artemis_config := servers["test-artemis-server"]
  expect_equals "toit-http" broker_config["type"]
  expect_equals "toit-http" artemis_config["type"]

  artemis_server_config := test_cli.artemis.server_config as ServerConfigHttp
  broker_server_config := test_cli.broker.server_config as ServerConfigHttp

  expect_equals artemis_server_config.host broker_server_config.host
  test_cli.replacements[artemis_server_config.host] = "<HOST>"
  expect_equals broker_server_config.host broker_config["host"]
  expect_equals artemis_server_config.host artemis_config["host"]
  expect_equals broker_server_config.port broker_config["port"]
  test_cli.replacements["$broker_server_config.port"] = "<B-PORT>"
  expect_equals artemis_server_config.port artemis_config["port"]
  test_cli.replacements["$artemis_server_config.port"] = "<A-PORT>"

  test_cli.replacements["$artemis_config["auth"]"] = "<ARTEMIS_AUTH>"

  test_cli.run_gold "BAA-config-show"
      "Print the test config"
      [
        "config", "show"
      ]

  fake_device := fake_devices[0] as FakeDevice

  test_cli.run [
    "--fleet-root", fleet_dir,
    "device", "default", "$fake_device.alias_id",
  ]

  test_cli.run [
    "--fleet-root", fleet_dir,
    "org", "default", "$fake_device.organization_id",
  ]

  json_config = test_cli.run --json [
    "--fleet-root", fleet_dir,
    "config", "show"
  ]
  expect_equals "$fake_device.alias_id" json_config["default-device"]
  expect_equals "$fake_device.organization_id" json_config["default-org"]

  test_cli.run_gold "BBA-config-show-default-values-set"
      "Print the test config with default values set"
      [
        "config", "show"
      ]
