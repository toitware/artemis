// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write-yaml-to-file
import expect show *
import .utils

main args:
  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  fleet.tester.ensure-available-artemis-service

  name := "test-pod"

  spec := {
      "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
      "name": "$name",
      "sdk-version": "$fleet.tester.sdk-version",
      "artemis-version": "$TEST-ARTEMIS-VERSION",
      "firmware-envelope": "esp32",
      "connections": [
        {
          "type": "wifi",
          "ssid": "test",
          "password": "test"
        }
      ]
    }
  spec-path := "$fleet.fleet-dir/$(name).yaml"
  write-yaml-to-file spec-path spec
  fleet.run [
    "pod", "upload", spec-path
  ]

  pods := fleet.run --json [
    "pod", "list", "--name", name
  ]
  expect-equals 1 pods.size
  expect-equals name pods[0]["name"]
  expect-equals 1 pods[0]["revision"]
  expect-equals 2 pods[0]["tags"].size
  expect (pods[0]["tags"].contains "latest")
