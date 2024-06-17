// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write-blob-to-file
import expect show *
import .utils

main args:
  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet

create-pods name/string fleet/TestFleet --count/int -> List:
  spec := """
    {
      "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
      "name": "$name",
      "sdk-version": "$fleet.test-cli.sdk-version",
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
    """
  spec-path := "$fleet.fleet-dir/$(name).json"
  write-blob-to-file spec-path spec
  count.repeat:
    fleet.run [
      "pod", "upload", spec-path
    ]
  pods := fleet.run --json [
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

run-test fleet/TestFleet:
  fleet.test-cli.ensure-available-artemis-service

  pod1-name := "pod1"
  tmp := create-pods pod1-name fleet --count=3
  description1-id := tmp[0]
  spec1-ids := tmp[1]

  pod2-name := "pod2"
  tmp = create-pods pod2-name fleet --count=2
  description2-id := tmp[0]
  spec2-ids := tmp[1]

  pod3-name := "pod3"
  tmp = create-pods pod3-name fleet --count=2
  description3-id := tmp[0]
  spec3-ids := tmp[1]

  fleet.run-gold "BAA-delete-pod-revision"
      "Delete a pod by revision"
      [
        "pod", "delete", "$pod1-name#2"
      ]
  pods := fleet.run --json [
    "pod", "list", "--name", pod1-name
  ]
  expect-equals 2 pods.size
  expect-equals spec1-ids[2] pods[0]["id"]
  // Revision 1 is now deleted.
  expect-equals spec1-ids[0] pods[1]["id"]

  fleet.run-gold "CAA-delete-pod-tag"
      "Delete a pod by tag"
      [
        // The latest is revision 2.
        "pod", "delete", "$pod2-name@latest"
      ]
  pods = fleet.run --json [
    "pod", "list", "--name", pod2-name
  ]
  expect-equals 1 pods.size
  expect-equals spec2-ids[0] pods[0]["id"]

  pod3-id2 := spec3-ids[1]
  fleet.test-cli.replacements["$pod3-id2"] = pad-replacement-id "POD3-ID"
  fleet.run-gold "CCA-delete-pod-id"
      "Delete a pod by id"
      [
        "pod", "delete", "$pod3-id2"
      ]
  pods = fleet.run --json [
    "pod", "list", "--name", pod3-name
  ]
  expect-equals 1 pods.size

  fleet.run-gold "DAA-delete-pods-by-name"
      "Delete pods by name"
      [
        "pod", "delete", "--all", pod1-name, pod3-name
      ]
  pods = fleet.run --json [
    "pod", "list"
  ]
  expect-equals 1 pods.size
  expect-equals spec2-ids[0] pods[0]["id"]

  fleet.run-gold --expect-exit-1 "EBA-delete-non-existing"
      "Can't delete non-existing"
      [
        "pod", "delete", "$pod1-name#2"
      ]

  // TODO(florian): would be nice to either give an error message, or
  // at least to not show "Deleted pods...".
  fleet.run-gold "EBb-delete-non-existing-id"
      "Delete non-existing id doesn't do anything"
      [
        "pod", "delete", "$pod3-id2"  // Was deleted earlier.
      ]

  fleet.run-gold --expect-exit-1 "EBD-delete-non-existing-many"
      "Can't delete non-existing many"
      [
        "pod", "delete", "$pod1-name#2", "$pod2-name@latest"
      ]

  fleet.run-gold --expect-exit-1 "ECA-delete-non-existing-description"
      "Can't delete non-existing description"
      [
        "pod", "delete", "--all", pod1-name
      ]

  fleet.run-gold --expect-exit-1 "ECC-delete-non-existing-description-many"
      "Can't delete non-existing description many"
      [
        "pod", "delete", "--all", pod1-name, pod3-name
      ]
