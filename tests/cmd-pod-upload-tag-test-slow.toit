// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write-yaml-to-file read-json
import expect show *
import host.file
import encoding.json
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
  spec-path := "$fleet-dir/$(name).yaml"
  write-yaml-to-file spec-path spec

  revision := 0
  test-cli.run [
    "pod", "upload", spec-path, "--tag", "some-tag"
  ]
  revision++
  add-pod-replacements.call ""

  test-cli.run-gold "BAA-upload-existing-tag"
      "Upload a pod with existing tag"
      --expect-exit-1
      --before-gold=add-pod-replacements
      [
        "pod", "upload", spec-path, "--tag", "some-tag"
      ]
  revision++

  test-cli.run-gold "BAC-upload-existing-tag-force"
      "Upload a pod with existing tag using --force"
      --before-gold=add-pod-replacements
      [
        "pod", "upload", spec-path, "--tag", "some-tag", "--force"
      ]
  revision++

  pod-path := "$fleet-dir/$(name).pod"
  test-cli.run [
    "pod", "build", "-o", pod-path, spec-path
  ]
  json-output := test-cli.run --json [
    "pod", "upload", pod-path
  ]
  revision++
  expect (json-output.contains "id")
  expect-equals revision json-output["revision"]
  expect (file.is-file pod-path)

  // Test that we can upload the same pod to a different fleet.
  with-tmp-directory: | fleet-dir2 |
    test-cli.replacements[fleet-dir2] = "<FLEET_ROOT2>"
    test-cli.run [
      "--fleet-root", fleet-dir2, "fleet", "init", "--organization-id", "$TEST-ORGANIZATION-UUID"
    ]
    fleet2 := read-json "$fleet-dir2/fleet.json"
    test-cli.replacements[fleet2["id"]] = pad-replacement-id "FLEET2-ID"

    // Note that we can use the same tag again.
    test-cli.run-gold "CAA-upload-to-different-fleet"
        "Upload a pod to a different fleet"
        --before-gold=add-pod-replacements
        [
          "--fleet-root", fleet-dir2, "pod", "upload", pod-path, "--tag", "some-tag"
        ]
