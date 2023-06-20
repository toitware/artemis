// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write_blob_to_file
import expect show *
import .utils

main args:
  with_fleet --count=0 --args=args: | test_cli/TestCli _ fleet_dir/string |
    run_test test_cli fleet_dir

run_test test_cli/TestCli fleet_dir/string:
  pod_name := "test-pod"

  add_pod_replacements := : | output/string |
    pods := test_cli.run --json [
      "pod", "list", "--name", pod_name
    ]
    pods.do:
      test_cli.replacements["$it["id"]"] = pad_replacement_id "ID $pod_name#$(it["revision"])"
    output

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
    "pod", "upload", spec_path, "--tag", "some-tag"
  ]
  add_pod_replacements.call ""

  test_cli.run_gold "BAA-upload-existing-tag"
      "Upload a pod with existing tag"
      --expect_exit_1
      --before_gold=add_pod_replacements
      [
        "pod", "upload", spec_path, "--tag", "some-tag"
      ]

  test_cli.run_gold "BAC-upload-existing-tag-force"
      "Upload a pod with existing tag using --force"
      --before_gold=add_pod_replacements
      [
        "pod", "upload", spec_path, "--tag", "some-tag", "--force"
      ]
