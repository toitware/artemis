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
  expect-equals "$fleet.tester.tmp-dir/config" json-config["path"]
  expect-equals "test-broker" json-config["default-broker"]
  servers := json-config["servers"]
  expect (servers.contains "test-broker")
  expect (servers.contains "test-artemis-server")

  broker-config := servers["test-broker"]
  artemis-config := servers["test-artemis-server"]
  expect-equals "toit-http" broker-config["type"]
  expect-equals "toit-http" artemis-config["type"]

  artemis-server-config := fleet.tester.artemis.server-config as ServerConfigHttp
  broker-server-config := fleet.tester.broker.server-config as ServerConfigHttp

  expect-equals artemis-server-config.host broker-server-config.host
  fleet.tester.replacements[artemis-server-config.host] = "<HOST>"
  expect-equals broker-server-config.host broker-config["host"]
  expect-equals artemis-server-config.host artemis-config["host"]
  expect-equals broker-server-config.port broker-config["port"]
  fleet.tester.replacements["$broker-server-config.port"] = "<B-PORT>"
  expect-equals artemis-server-config.port artemis-config["port"]
  fleet.tester.replacements["$artemis-server-config.port"] = "<A-PORT>"

  fleet.tester.replacements["$artemis-config["auth"]"] = "<ARTEMIS_AUTH>"

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

  RECOVERY-SERVERS ::= [
    "https://example.com",
    "http://example.com",
  ]

  RECOVERY-SERVERS.do: | url/string |
    fleet.run [
      "config", "recovery", "add", "$url",
    ]

  stored-servers := fleet.run --json [
    "config", "recovery", "list"
  ]
  expect-list-equals RECOVERY-SERVERS stored-servers

  json-config = fleet.run --json [
    "config", "show"
  ]
  expect-equals "$fake-device.alias-id" json-config["default-device"]
  expect-equals "$fake-device.organization-id" json-config["default-org"]
  expect-list-equals RECOVERY-SERVERS json-config["recovery-servers"]

  with-tmp-directory: | fleet-tmp-dir/string |
    init-data := fleet.run --json [
      "fleet", "init", "--fleet", fleet-tmp-dir,
    ]
    fleet-id := init-data["id"]
    recovery-urls := init-data["recovery-urls"]
    mapped := RECOVERY-SERVERS.map: "$it/recover-$(fleet-id).json"
    expect-list-equals mapped recovery-urls

  with-tmp-directory: | fleet-tmp-dir/string |
    fleet.tester.replacements["$fleet-tmp-dir"] = "<FLEET-TMP-DIR>"
    fleet.tester.run-gold "BAC-init-recovery"
        "Show the recovery servers"
        ["fleet", "init", "--fleet", fleet-tmp-dir]
        --before-gold=: | output/string |
          recover-prefix := "/recover-"
          recover-index := output.index-of recover-prefix
          json-index := output.index-of ".json" recover-index
          fleet-id := output[recover-index + recover-prefix.size .. json-index]
          output.replace --all fleet-id "<FLEET-ID>"


  fleet.run-gold "BBA-config-show-default-values-set"
      "Print the test config with default values set"
      [
        "config", "show"
      ]

  fleet.run [
    "config", "recovery", "remove", RECOVERY-SERVERS.first,
  ]

  stored-servers = fleet.run --json [
    "config", "recovery", "list"
  ]

  expect-list-equals RECOVERY-SERVERS[1..] stored-servers

  fleet.run --expect-exit-1 [
    "config", "recovery", "remove", RECOVERY-SERVERS.first,
  ]

  fleet.run [
    "config", "recovery", "remove", "--force", RECOVERY-SERVERS.first,
  ]

  stored-servers = fleet.run --json [
    "config", "recovery", "list"
  ]

  expect-list-equals RECOVERY-SERVERS[1..] stored-servers

  fleet.run [
    "config", "recovery", "remove", "--all",
  ]

  stored-servers = fleet.run --json [
    "config", "recovery", "list"
  ]

  expect-list-equals [] stored-servers

  fleet.run-gold "DAA-config-broker-default-non-existing"
      "Try to set the default broker to a non-existing broker"
      --expect-exit-1
      [
        "config", "broker", "default", "non-existing"
      ]

  servers-in-config := fleet.tester.cli.config.get CONFIG-SERVERS-KEY
  fleet.tester.cli.config.remove CONFIG-SERVERS-KEY

  fleet.run-gold "DAB-config-broker-default-non-existing-no-servers"
      "Try to set the default broker to a non-existing broker when there are no servers"
      --expect-exit-1
      [
        "config", "broker", "default", "non-existing"
      ]

  fleet.tester.cli.config[CONFIG-SERVERS-KEY] = servers-in-config
