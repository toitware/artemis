// Copyright (C) 2023 Toitware ApS.

import ar show ArReader
import artemis.cli.utils show write_blob_to_file
import artemis.cli.firmware show get_envelope
import artemis.cli.pod show Pod
import artemis.cli.pod_specification show PodSpecification
import artemis.cli.sdk show Sdk
import bytes
import expect show *
import host.file
import .utils

main args:
  with_fleet --count=0 --args=args: | test_cli/TestCli _ fleet_dir/string |
    run_test test_cli fleet_dir

run_test test_cli/TestCli fleet_dir/string:
  test_cli.ensure_available_artemis_service

  spec := """
    {
      "version": 1,
      "name": "test-pod",
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
  spec_path := "$fleet_dir/test-pod.json"
  write_blob_to_file spec_path spec
  test_cli.run [
    "pod", "build", spec_path, "-o", "$fleet_dir/test-pod.pod"
  ]
  validate_pod "$fleet_dir/test-pod.pod"
      --name="test-pod"
      --containers=["artemis"]
      --test_cli=test_cli

  // Test custom firmwares.
  spec = """
    {
      "version": 1,
      "name": "test-pod2",
      "firmware-envelope": "./custom.envelope",
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
  spec_path = "$fleet_dir/test-pod2.json"
  write_blob_to_file spec_path spec

  custom_path := "$fleet_dir/custom.envelope"

  default_envelope := get_envelope_for --sdk_version=test_cli.sdk_version --cache=test_cli.cache
  write_blob_to_file custom_path default_envelope

  print "custom-path: $custom_path"
  sdk := Sdk --envelope_path=custom_path --cache=test_cli.cache
  custom_program := """
  main: print "custom"
  """
  custom_toit := "$fleet_dir/custom.toit"
  custom_snapshot := "$fleet_dir/custom.snapshot"
  write_blob_to_file custom_toit custom_program
  sdk.compile_to_snapshot --out=custom_snapshot custom_toit
  sdk.firmware_add_container "custom"
      --envelope=custom_path
      --program_path=custom_snapshot
      --trigger="none"

  test_cli.run [
    "pod", "build", spec_path, "-o", "$fleet_dir/test-pod2.pod"
  ]
  validate_pod "$fleet_dir/test-pod2.pod"
      --name="test-pod2"
      --containers=["artemis", "custom"]
      --test_cli=test_cli

validate_pod pod_path/string --name/string --containers/List --test_cli/TestCli:
  artemis := test_cli
  with_tmp_directory: | tmp_dir |
    pod := Pod.parse pod_path --tmp_directory=tmp_dir --ui=(TestUi --no-quiet)
    expect_equals name pod.name
    envelope := pod.envelope
    seen := {}
    reader := ArReader (bytes.Reader envelope)
    while file := reader.next:
      seen.add file.name
    containers.do:
      expect (seen.contains it)

get_envelope_for --sdk_version/string --cache -> ByteArray:
  default_spec := {
      "version": 1,
      "name": "test-pod2",
      "artemis-version": "$TEST_ARTEMIS_VERSION",
      "sdk-version": "$sdk_version",
      "connections": [
        {
          "type": "wifi",
          "ssid": "test",
          "password": "test"
        }
      ]
    }
  pod_specification := PodSpecification.from_json default_spec --path="ignored"

  default_envelope_path := get_envelope --specification=pod_specification --cache=cache
  return file.read_content default_envelope_path
