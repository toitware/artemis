// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config show CONFIG-SERVERS-KEY
import artemis.shared.server-config show ServerConfigHttp
import expect show *
import .utils

main args:
  with-fleet --args=args --count=1: | test-cli/TestCli fake-devices/List fleet-dir/string |
    run-test test-cli fake-devices fleet-dir

run-test test-cli/TestCli fake-devices/List fleet-dir/string:
  json-config := test-cli.run --json [
    "config", "show"
  ]
  expect-equals "$test-cli.tmp-dir/config" json-config["path"]
  expect-equals "test-broker" json-config["default-broker"]
  servers := json-config["servers"]
  expect (servers.contains "test-broker")
  expect (servers.contains "test-artemis-server")

  broker-config := servers["test-broker"]
  artemis-config := servers["test-artemis-server"]
  expect-equals "toit-http" broker-config["type"]
  expect-equals "toit-http" artemis-config["type"]

  artemis-server-config := test-cli.artemis.server-config as ServerConfigHttp
  broker-server-config := test-cli.broker.server-config as ServerConfigHttp

  expect-equals artemis-server-config.host broker-server-config.host
  test-cli.replacements[artemis-server-config.host] = "<HOST>"
  expect-equals broker-server-config.host broker-config["host"]
  expect-equals artemis-server-config.host artemis-config["host"]
  expect-equals broker-server-config.port broker-config["port"]
  test-cli.replacements["$broker-server-config.port"] = "<B-PORT>"
  expect-equals artemis-server-config.port artemis-config["port"]
  test-cli.replacements["$artemis-server-config.port"] = "<A-PORT>"

  test-cli.replacements["$artemis-config["auth"]"] = "<ARTEMIS_AUTH>"

  test-cli.run-gold "BAA-config-show"
      "Print the test config"
      [
        "config", "show"
      ]

  fake-device := fake-devices[0] as FakeDevice

  test-cli.run [
    "device", "default", "$fake-device.alias-id",
  ]

  test-cli.run [
    "org", "default", "$fake-device.organization-id",
  ]

  json-config = test-cli.run --json [
    "config", "show"
  ]
  expect-equals "$fake-device.alias-id" json-config["default-device"]
  expect-equals "$fake-device.organization-id" json-config["default-org"]

  test-cli.run-gold "BBA-config-show-default-values-set"
      "Print the test config with default values set"
      [
        "config", "show"
      ]

  test-cli.run-gold "DAA-config-broker-default-non-existing"
      "Try to set the default broker to a non-existing broker"
      --expect-exit-1
      [
        "config", "broker", "default", "non-existing"
      ]

  servers-in-config := test-cli.config.get CONFIG-SERVERS-KEY
  test-cli.config.remove CONFIG-SERVERS-KEY

  test-cli.run-gold "DAB-config-broker-default-non-existing-no-servers"
      "Try to set the default broker to a non-existing broker when there are no servers"
      --expect-exit-1
      [
        "config", "broker", "default", "non-existing"
      ]

  test-cli.config[CONFIG-SERVERS-KEY] = servers-in-config
