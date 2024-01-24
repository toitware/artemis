// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write-yaml-to-file
import expect show *
import .utils

main args:
  with-fleet --count=0 --args=args: | test-cli/TestCli _ fleet-dir/string |
    run-test test-cli fleet-dir

run-test test-cli/TestCli fleet-dir/string:
  test-cli.ensure-available-artemis-service

  name := "test-pod"

  spec := {
      "version": 1,
      "name": "$name",
      "sdk-version": "$test-cli.sdk-version",
      "artemis-version": "$TEST-ARTEMIS-VERSION",
      "connections": [
        {
          "type": "wifi",
          "ssid": "test",
          "password": "test"
        }
      ]
    }
  spec-path := "$fleet-dir/$(name).yaml"
  write-yaml-to-file spec-path spec
  test-cli.run [
    "pod", "upload", spec-path
  ]

  pods := test-cli.run --json [
    "pod", "list", "--name", name
  ]
  expect-equals 1 pods.size
  expect-equals name pods[0]["name"]
  expect-equals 1 pods[0]["revision"]
  expect-equals 2 pods[0]["tags"].size
  expect (pods[0]["tags"].contains "latest")
