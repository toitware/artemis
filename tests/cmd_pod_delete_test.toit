// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: BROKER

import artemis.cli.utils show write_blob_to_file
import expect show *
import .utils

main args:
  with_fleet --count=0 --args=args: | test_cli/TestCli _ fleet_dir/string |
    run_test test_cli fleet_dir

create_pods name/string test_cli/TestCli fleet_dir/string --count/int -> List:
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
  count.repeat:
    test_cli.run [
      "--fleet-root", fleet_dir,
      "pod", "upload", spec_path
    ]
  pods := test_cli.run --json [
    "--fleet-root", fleet_dir,
    "pod", "list", "--name", name
  ]
  expect_equals count pods.size
  spec_ids := List count
  description_id := -1

  pods.do:
    id := it["id"]
    revision := it["revision"]
    description_id = it["pod_description_id"]
    spec_ids[revision - 1] = id

  return [description_id, spec_ids]

run_test test_cli/TestCli fleet_dir/string:
  test_cli.ensure_available_artemis_service

  pod1_name := "pod1"
  tmp := create_pods pod1_name test_cli fleet_dir --count=3
  description1_id := tmp[0]
  spec1_ids := tmp[1]

  pod2_name := "pod2"
  tmp = create_pods pod2_name test_cli fleet_dir --count=2
  description2_id := tmp[0]
  spec2_ids := tmp[1]

  pod3_name := "pod3"
  tmp = create_pods pod3_name test_cli fleet_dir --count=2
  description3_id := tmp[0]
  spec3_ids := tmp[1]

  test_cli.run_gold "BAA-delete-pod-revision"
      "Delete a pod by revision"
      [
        "--fleet-root", fleet_dir,
        "pod", "delete", "$pod1_name#2"
      ]
  pods := test_cli.run --json [
    "--fleet-root", fleet_dir,
    "pod", "list", "--name", pod1_name
  ]
  expect_equals 2 pods.size
  expect_equals spec1_ids[2] pods[0]["id"]
  // Revision 1 is now deleted.
  expect_equals spec1_ids[0] pods[1]["id"]

  test_cli.run_gold "CAA-delete-pod-tag"
      "Delete a pod by tag"
      [
        "--fleet-root", fleet_dir,
        // The latest is revision 2.
        "pod", "delete", "$pod2_name@latest"
      ]
  pods = test_cli.run --json [
    "--fleet-root", fleet_dir,
    "pod", "list", "--name", pod2_name
  ]
  expect_equals 1 pods.size
  expect_equals spec2_ids[0] pods[0]["id"]

  pod3_id2 := spec3_ids[1]
  test_cli.replacements["$pod3_id2"] = pad_replacement_id "POD3-ID"
  test_cli.run_gold "CCA-delete-pod-id"
      "Delete a pod by id"
      [
        "--fleet-root", fleet_dir,
        "pod", "delete", "$pod3_id2"
      ]
  pods = test_cli.run --json [
    "--fleet-root", fleet_dir,
    "pod", "list", "--name", pod3_name
  ]
  expect_equals 1 pods.size

  test_cli.run_gold "DAA-delete-pods-by-name"
      "Delete pods by name"
      [
        "--fleet-root", fleet_dir,
        "pod", "delete", "--all", pod1_name, pod3_name
      ]
  pods = test_cli.run --json [
    "--fleet-root", fleet_dir,
    "pod", "list"
  ]
  expect_equals 1 pods.size
  expect_equals spec2_ids[0] pods[0]["id"]

  test_cli.run_gold --expect_exit_1 "EBA-delete-non-existing"
      "Can't delete non-existing"
      [
        "--fleet-root", fleet_dir,
        "pod", "delete", "$pod1_name#2"
      ]

  // TODO(florian): would be nice to either give an error message, or
  // at least to not show "Deleted pods...".
  test_cli.run_gold "EBb-delete-non-existing-id"
      "Delete non-existing id doesn't do anything"
      [
        "--fleet-root", fleet_dir,
        "pod", "delete", "$pod3_id2"  // Was deleted earlier.
      ]

  test_cli.run_gold --expect_exit_1 "EBD-delete-non-existing-many"
      "Can't delete non-existing many"
      [
        "--fleet-root", fleet_dir,
        "pod", "delete", "$pod1_name#2", "$pod2_name@latest"
      ]

  test_cli.run_gold --expect_exit_1 "ECA-delete-non-existing-description"
      "Can't delete non-existing description"
      [
        "--fleet-root", fleet_dir,
        "pod", "delete", "--all", pod1_name
      ]

  test_cli.run_gold --expect_exit_1 "ECC-delete-non-existing-description-many"
      "Can't delete non-existing description many"
      [
        "--fleet-root", fleet_dir,
        "pod", "delete", "--all", pod1_name, pod3_name
      ]
