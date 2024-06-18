// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config show CONFIG-SERVERS-KEY
import artemis.shared.server-config show ServerConfigHttp
import expect show *
import .utils

main args:
  with-fleet --args=args --count=1: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  json-config := fleet.run --json [
    "config", "show"
  ]
  expect-equals "$fleet.test-cli.tmp-dir/config" json-config["path"]
  expect-equals "test-broker" json-config["default-broker"]
  servers := json-config["servers"]
  expect (servers.contains "test-broker")
  expect (servers.contains "test-artemis-server")

  broker-config := servers["test-broker"]
  artemis-config := servers["test-artemis-server"]
  expect-equals "toit-http" broker-config["type"]
  expect-equals "toit-http" artemis-config["type"]

  artemis-server-config := fleet.test-cli.artemis.server-config as ServerConfigHttp
  broker-server-config := fleet.test-cli.broker.server-config as ServerConfigHttp

  expect-equals artemis-server-config.host broker-server-config.host
  fleet.test-cli.replacements[artemis-server-config.host] = "<HOST>"
  expect-equals broker-server-config.host broker-config["host"]
  expect-equals artemis-server-config.host artemis-config["host"]
  expect-equals broker-server-config.port broker-config["port"]
  fleet.test-cli.replacements["$broker-server-config.port"] = "<B-PORT>"
  expect-equals artemis-server-config.port artemis-config["port"]
  fleet.test-cli.replacements["$artemis-server-config.port"] = "<A-PORT>"

  fleet.test-cli.replacements["$artemis-config["auth"]"] = "<ARTEMIS_AUTH>"

  fleet.run-gold "BAA-config-show"
      "Print the test config"
      [
        "config", "show"
      ]

  fake-device := fleet.devices.values[0] as FakeDevice

  fleet.run [
    "device", "default", "$fake-device.alias-id",
  ]

  fleet.run [
    "org", "default", "$fake-device.organization-id",
  ]

  json-config = fleet.run --json [
    "config", "show"
  ]
  expect-equals "$fake-device.alias-id" json-config["default-device"]
  expect-equals "$fake-device.organization-id" json-config["default-org"]

  fleet.run-gold "BBA-config-show-default-values-set"
      "Print the test config with default values set"
      [
        "config", "show"
      ]

  fleet.run-gold "DAA-config-broker-default-non-existing"
      "Try to set the default broker to a non-existing broker"
      --expect-exit-1
      [
        "config", "broker", "default", "non-existing"
      ]

  servers-in-config := fleet.test-cli.config.get CONFIG-SERVERS-KEY
  fleet.test-cli.config.remove CONFIG-SERVERS-KEY

  fleet.run-gold "DAB-config-broker-default-non-existing-no-servers"
      "Try to set the default broker to a non-existing broker when there are no servers"
      --expect-exit-1
      [
        "config", "broker", "default", "non-existing"
      ]

  fleet.test-cli.config[CONFIG-SERVERS-KEY] = servers-in-config
