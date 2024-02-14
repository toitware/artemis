// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write-yaml-to-file
import encoding.json
import expect show *
import host.file
import host.os
import .utils

main args:
  with-test-cli --args=args: | test-cli/TestCli |
    with-fleet --count=0 --args=args --test-cli=test-cli: | _ fleet-dir1/string |
      with-fleet --count=0 --args=args --test-cli=test-cli: | _ fleet-dir2/string |
        run-test test-cli fleet-dir1 fleet-dir2

run-test test-cli/TestCli fleet-dir1/string fleet-dir2/string:
  os.env["ARTEMIS_FLEET_ROOT"] = fleet-dir1
  test-cli.ensure-available-artemis-service

  name := "test-pod"

  spec := {
      "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
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
  spec-path := "$fleet-dir1/$(name).yaml"
  write-yaml-to-file spec-path spec
  test-cli.run [
    "--fleet-root", fleet-dir1, "pod", "upload", spec-path
  ]

  pods := test-cli.run --json [
    "--fleet-root", fleet-dir1, "pod", "list", "--name", name
  ]
  expect-equals 1 pods.size
  expect-equals name pods[0]["name"]
  expect-equals 1 pods[0]["revision"]
  expect-equals 2 pods[0]["tags"].size
  expect (pods[0]["tags"].contains "latest")

  // Test that it's possible to upload a pod to a different fleet in the same org.
  fleet2-json := json.decode (file.read-content "$fleet-dir2/fleet.json")
  fleet2-id := fleet2-json["id"]

  pods = test-cli.run --json [
    "--fleet-root", fleet-dir2, "pod", "list"
  ]
  expect-equals 0 pods.size

  test-cli.run [
    "--fleet-root", fleet-dir1, "pod", "upload", spec-path, "--fleet", fleet2-id
  ]

  pods = test-cli.run --json [
    "--fleet-root", fleet-dir2, "pod", "list"
  ]
  expect-equals 1 pods.size

  pods = test-cli.run --json [
    "--fleet-root", fleet-dir1, "pod", "list"
  ]
  expect-equals 1 pods.size
