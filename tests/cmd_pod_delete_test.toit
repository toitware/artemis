// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write-blob-to-file
import expect show *
import .utils

main args:
  with-fleet --count=0 --args=args: | test-cli/TestCli _ fleet-dir/string |
    run-test test-cli fleet-dir

create-pods name/string test-cli/TestCli fleet-dir/string --count/int -> List:
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
  count.repeat:
    test-cli.run [
      "pod", "upload", spec-path
    ]
  pods := test-cli.run --json [
    "pod", "list", "--name", name
  ]
  expect-equals count pods.size
  spec-ids := List count
  description-id := -1

  pods.do:
    id := it["id"]
    revision := it["revision"]
    description-id = it["pod_description_id"]
    spec-ids[revision - 1] = id

  return [description-id, spec-ids]

run-test test-cli/TestCli fleet-dir/string:
  test-cli.ensure-available-artemis-service

  pod1-name := "pod1"
  tmp := create-pods pod1-name test-cli fleet-dir --count=3
  description1-id := tmp[0]
  spec1-ids := tmp[1]

  pod2-name := "pod2"
  tmp = create-pods pod2-name test-cli fleet-dir --count=2
  description2-id := tmp[0]
  spec2-ids := tmp[1]

  pod3-name := "pod3"
  tmp = create-pods pod3-name test-cli fleet-dir --count=2
  description3-id := tmp[0]
  spec3-ids := tmp[1]

  test-cli.run-gold "BAA-delete-pod-revision"
      "Delete a pod by revision"
      [
        "pod", "delete", "$pod1-name#2"
      ]
  pods := test-cli.run --json [
    "pod", "list", "--name", pod1-name
  ]
  expect-equals 2 pods.size
  expect-equals spec1-ids[2] pods[0]["id"]
  // Revision 1 is now deleted.
  expect-equals spec1-ids[0] pods[1]["id"]

  test-cli.run-gold "CAA-delete-pod-tag"
      "Delete a pod by tag"
      [
        // The latest is revision 2.
        "pod", "delete", "$pod2-name@latest"
      ]
  pods = test-cli.run --json [
    "pod", "list", "--name", pod2-name
  ]
  expect-equals 1 pods.size
  expect-equals spec2-ids[0] pods[0]["id"]

  pod3-id2 := spec3-ids[1]
  test-cli.replacements["$pod3-id2"] = pad-replacement-id "POD3-ID"
  test-cli.run-gold "CCA-delete-pod-id"
      "Delete a pod by id"
      [
        "pod", "delete", "$pod3-id2"
      ]
  pods = test-cli.run --json [
    "pod", "list", "--name", pod3-name
  ]
  expect-equals 1 pods.size

  test-cli.run-gold "DAA-delete-pods-by-name"
      "Delete pods by name"
      [
        "pod", "delete", "--all", pod1-name, pod3-name
      ]
  pods = test-cli.run --json [
    "pod", "list"
  ]
  expect-equals 1 pods.size
  expect-equals spec2-ids[0] pods[0]["id"]

  test-cli.run-gold --expect-exit-1 "EBA-delete-non-existing"
      "Can't delete non-existing"
      [
        "pod", "delete", "$pod1-name#2"
      ]

  // TODO(florian): would be nice to either give an error message, or
  // at least to not show "Deleted pods...".
  test-cli.run-gold "EBb-delete-non-existing-id"
      "Delete non-existing id doesn't do anything"
      [
        "pod", "delete", "$pod3-id2"  // Was deleted earlier.
      ]

  test-cli.run-gold --expect-exit-1 "EBD-delete-non-existing-many"
      "Can't delete non-existing many"
      [
        "pod", "delete", "$pod1-name#2", "$pod2-name@latest"
      ]

  test-cli.run-gold --expect-exit-1 "ECA-delete-non-existing-description"
      "Can't delete non-existing description"
      [
        "pod", "delete", "--all", pod1-name
      ]

  test-cli.run-gold --expect-exit-1 "ECC-delete-non-existing-description-many"
      "Can't delete non-existing description many"
      [
        "pod", "delete", "--all", pod1-name, pod3-name
      ]
