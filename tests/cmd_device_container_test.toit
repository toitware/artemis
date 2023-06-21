// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli.pod_specification show INITIAL_POD_SPECIFICATION
import artemis.cli.utils show write_json_to_file write_blob_to_file
import .utils

main args:
  with_fleet --args=args --count=1: | test_cli/TestCli fake_devices/List fleet_dir/string |
    run_test test_cli fake_devices fleet_dir

run_test test_cli/TestCli fake_devices/List fleet_dir/string:
  tmp_dir := test_cli.tmp_dir

  device/FakeDevice := fake_devices[0]
  device.report_state

  hello_path := "$tmp_dir/hello.toit"
  write_blob_to_file hello_path """
      main: print "hello world"
      """

  test_cli.run [
    "device", "default", "$device.alias_id"
  ]

  test_cli.run_gold "200_install"
      "Install a container"
      [
        "device", "container", "install", "hello", hello_path
      ]

  test_cli.run_gold "220_uninstall"
      "Uninstall a container"
      [
        "device", "container", "uninstall", "hello"
      ]

  test_cli.run_gold "230_uninstall_non_existing"
      --expect_exit_1
      "Uninstall a non-existing container"
      [
        "device", "container", "uninstall", "hello"
      ]

  // Force allows uninstalling a container that is not installed.
  test_cli.run_gold "240_uninstall_non_existing_force"
      "Uninstall a non-existing container with force"
      [
        "device", "container", "uninstall", "hello", "--force"
      ]

  test_cli.ensure_available_artemis_service
      --sdk_version=TEST_SDK_VERSION
      --artemis_version=TEST_ARTEMIS_VERSION

  pod_spec := deep_copy_ INITIAL_POD_SPECIFICATION

  pod_spec["sdk-version"] = TEST_SDK_VERSION
  pod_spec["artemis-version"] = TEST_ARTEMIS_VERSION

  pod_spec["connections"] = [
    {
      "type": "cellular",
      "config": {:},
      "requires": ["hello"]
    },
    {
      "type": "wifi",
      "ssid": "test-ssid",
      "password": "test-password",
    }
  ]
  pod_spec["containers"] = {
    "hello": {
      "entrypoint": "hello.toit"
    }
  }

  spec_file := "$tmp_dir/test.json"
  pod_file := "$tmp_dir/test.pod"
  write_json_to_file spec_file pod_spec

  test_cli.run [
    "pod", "create", spec_file, "-o", pod_file
  ]

  test_cli.run [
    "device", "update", "--local", pod_file
  ]

  device.synchronize
  device.flash
  device.reboot
  device.report_state

  // Hello is now a required container.
  test_cli.run_gold "300_uninstall_required"
      "Can't uninstall required container without force"
      --expect_exit_1
      [
        "device", "container", "uninstall", "hello"
      ]

  // Works with force.
  test_cli.run_gold "310_uninstall_required_force"
      "Can uninstall required container with force"
      [
        "device", "container", "uninstall", "hello", "--force"
      ]
