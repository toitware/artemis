// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write_blob_to_file
import expect show *
import .utils

main args:
  with_fleet --count=0 --args=args: | test_cli/TestCli _ fleet_dir/string |
    run_test test_cli fleet_dir

run_test test_cli/TestCli fleet_dir/string:
  test_cli.ensure_available_artemis_service

  name := "test-pod"

  spec := """
    {
      "version": 1,
      "name": "$name",
      "sdk-version": "$test_cli.sdk_version",
      "artemis-version": "$TEST_ARTEMIS_VERSION",
      "connections": [
        {
          "type": "wifi",
          "ssid": "test",
          "password": "test"
        }
      ]
    }
    """
  spec_path := "$fleet_dir/$(name).json"
  write_blob_to_file spec_path spec
  test_cli.run [
    "--fleet-root", fleet_dir,
    "pod", "upload", spec_path
  ]

  pods := test_cli.run --json [
    "--fleet-root", fleet_dir,
    "pod", "list", "--name", name
  ]
  expect_equals 1 pods.size
  expect_equals name pods[0]["name"]
  expect_equals 1 pods[0]["revision"]
  expect_equals 2 pods[0]["tags"].size
  expect (pods[0]["tags"].contains "latest")
