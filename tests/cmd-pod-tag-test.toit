// Copyright (C) 2024 Toitware ApS.

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
  name2 := "test-pod2"

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
  // Upload it again to have two pods with the same name.
  fleet.run [
    "pod", "upload", spec-path
  ]

  spec["name"] = name2
  spec-path = "$fleet.fleet-dir/$(name2).yaml"
  write-yaml-to-file spec-path spec
  fleet.run [
    "pod", "upload", spec-path
  ]

  fleet.run-gold "AAA-add-tag"
      "Add a tag to a pod"
      [
        "pod", "tag", "add", "-t", "foo", "$name#1"
      ]

  fleet.run-gold "AAB-add-tags"
      "Add a multiple tags to multiple pods"
      [
        "pod", "tag", "add", "-t", "bar", "-t", "gee", "$name@foo", name2
      ]

  fleet.run-gold --expect-exit-1 "ABA-add-tags-fail"
      "Add a tag to a non-existing pod"
      [
        "pod", "tag", "add", "-t", "bar", "non-existing"
      ]

  fleet.run-gold --expect-exit-1 "ABB-add-tags-fail"
      "Add existing tag to a pod"
      [
        "pod", "tag", "add", "-t", "foo", "$name#2"
      ]

  fleet.run-gold "ACA-add-tags-force"
      "Add existing tag to a pod with force"
      [
        "pod", "tag", "add", "-t", "foo", "--force", "$name#2"
      ]

  pods := fleet.run --json [
    "pod", "list", "--name", name
  ]
  expect-equals 2 pods.size
  revision-to-pod := {:}
  pods.do:
    revision-to-pod[it["revision"]] = it

  pod-1 := revision-to-pod[1]
  expect-equals 1 pod-1["revision"]
  expect-equals 3 pod-1["tags"].size
  ["bar", "gee"].do:
    expect (pod-1["tags"].contains it)

  pod-2 := revision-to-pod[2]
  expect-equals name pod-2["name"]
  expect-equals 2 pod-2["revision"]
  expect-equals 3 pod-2["tags"].size
  ["latest", "foo"].do:
    expect (pod-2["tags"].contains it)

  pods = fleet.run --json [
    "pod", "list", "--name", name2
  ]
  expect-equals 1 pods.size
  expect-equals name2 pods[0]["name"]
  expect-equals 1 pods[0]["revision"]
  expect-equals 4 pods[0]["tags"].size
  ["latest", "bar", "gee"].do:
    expect (pods[0]["tags"].contains it)

  fleet.run-gold "DAA-remove-tags"
      "Remove non-existing tags from a pod"
      [
        "pod", "tag", "remove", "-t", "non-existing", "-t", "non-existing2", name
      ]

  fleet.run-gold "DAB-remove-tags"
      "Remove tags from a pod"
      [
        "pod", "tag", "remove", "-t", "foo", name
      ]

  fleet.run-gold "DAC-remove-multiple-tags"
      "Remove tags from multiple pods"
      [
        "pod", "tag", "remove", "-t", "bar", name, name2
      ]

  fleet.run-gold "DAD-remove-latest"
      "Remove the 'latest' tag from a pod"
      [
        "pod", "tag", "remove", "-t", "latest", name2
      ]

  pods = fleet.run --json [
    "pod", "list", "--name", name
  ]
  expect-equals 2 pods.size
  revision-to-pod = {:}
  pods.do:
    revision-to-pod[it["revision"]] = it

  pod-1 = revision-to-pod[1]
  expect-equals 2 pod-1["tags"].size
  ["gee"].do:
    expect (pod-1["tags"].contains it)

  pod-2 = revision-to-pod[2]
  expect-equals 2 pod-2["tags"].size
  ["latest"].do:
    expect (pod-2["tags"].contains it)

  pods = fleet.run --json [
    "pod", "list", "--name", name2
  ]
  expect-equals 1 pods.size
  expect-equals 2 pods[0]["tags"].size
  ["gee"].do:
    expect (pods[0]["tags"].contains it)
