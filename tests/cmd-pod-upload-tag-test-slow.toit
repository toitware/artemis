// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write-yaml-to-file read-json
import expect show *
import host.file
import encoding.json
import .utils

main args:
  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  fleet-dir := fleet.fleet-dir
  tester := fleet.tester
  pod-name := "test-pod"

  add-pod-replacements := : | output/string |
    pods := fleet.run --json [
      "pod", "list", "--name", pod-name
    ]
    pods.do:
      tester.replacements["$it["id"]"] = pad-replacement-id "ID $pod-name#$(it["revision"])"
    output

  tester.ensure-available-artemis-service

  name := "test-pod"
  spec := {
      "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
      "name": "$name",
      "sdk-version": "$tester.sdk-version",
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
  spec-path := "$fleet-dir/$(name).yaml"
  write-yaml-to-file spec-path spec

  revision := 0
  tester.run [
    "pod", "upload", spec-path, "--tag", "some-tag"
  ]
  revision++
  add-pod-replacements.call ""

  tester.run-gold "BAA-upload-existing-tag"
      "Upload a pod with existing tag"
      --expect-exit-1
      --before-gold=add-pod-replacements
      [
        "pod", "upload", spec-path, "--tag", "some-tag"
      ]
  revision++

  tester.run-gold "BAC-upload-existing-tag-force"
      "Upload a pod with existing tag using --force"
      --before-gold=add-pod-replacements
      [
        "pod", "upload", spec-path, "--tag", "some-tag", "--force"
      ]
  revision++

  pod-path := "$fleet-dir/$(name).pod"
  tester.run [
    "pod", "build", "-o", pod-path, spec-path
  ]
  json-output := tester.run --json [
    "pod", "upload", pod-path
  ]
  revision++
  expect (json-output.contains "id")
  expect-equals revision json-output["revision"]
  expect (file.is-file pod-path)

  // Test that we can upload the same pod to a different fleet.
  with-tmp-directory: | fleet-dir2 |
    tester.replacements[fleet-dir2] = "<FLEET_ROOT2>"
    tester.run [
      "--fleet-root", fleet-dir2, "fleet", "init", "--organization-id", "$TEST-ORGANIZATION-UUID"
    ]
    fleet2 := read-json "$fleet-dir2/fleet.json"
    tester.replacements[fleet2["id"]] = pad-replacement-id "FLEET2-ID"

    // Note that we can use the same tag again.
    tester.run-gold "CAA-upload-to-different-fleet"
        "Upload a pod to a different fleet"
        --before-gold=add-pod-replacements
        [
          "--fleet-root", fleet-dir2, "pod", "upload", pod-path, "--tag", "some-tag"
        ]
