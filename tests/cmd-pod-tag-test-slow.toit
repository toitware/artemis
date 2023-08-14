// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write-blob-to-file
import expect show *
import .utils

main args:
  with-fleet --count=0 --args=args: | test-cli/TestCli _ fleet-dir/string |
    run-test test-cli fleet-dir

run-test test-cli/TestCli fleet-dir/string:
  pod-name := "test-pod"

  add-pod-replacements := : | output/string |
    pods := test-cli.run --json [
      "pod", "list", "--name", pod-name
    ]
    pods.do:
      test-cli.replacements["$it["id"]"] = pad-replacement-id "ID $pod-name#$(it["revision"])"
    output

  test-cli.ensure-available-artemis-service

  name := "test-pod"
  spec := """
    {
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
    """
  spec-path := "$fleet-dir/$(name).json"
  write-blob-to-file spec-path spec

  test-cli.run [
    "pod", "upload", spec-path, "--tag", "some-tag"
  ]
  add-pod-replacements.call ""

  test-cli.run-gold "BAA-upload-existing-tag"
      "Upload a pod with existing tag"
      --expect-exit-1
      --before-gold=add-pod-replacements
      [
        "pod", "upload", spec-path, "--tag", "some-tag"
      ]

  test-cli.run-gold "BAC-upload-existing-tag-force"
      "Upload a pod with existing tag using --force"
      --before-gold=add-pod-replacements
      [
        "pod", "upload", spec-path, "--tag", "some-tag", "--force"
      ]
