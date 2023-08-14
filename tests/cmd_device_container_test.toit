// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli.pod-specification show INITIAL-POD-SPECIFICATION
import artemis.cli.utils show write-json-to-file write-blob-to-file
import .utils

main args:
  with-fleet --args=args --count=1: | test-cli/TestCli fake-devices/List fleet-dir/string |
    run-test test-cli fake-devices fleet-dir

run-test test-cli/TestCli fake-devices/List fleet-dir/string:
  tmp-dir := test-cli.tmp-dir

  device/FakeDevice := fake-devices[0]
  device.report-state

  hello-path := "$tmp-dir/hello.toit"
  write-blob-to-file hello-path """
      main: print "hello world"
      """

  test-cli.run [
    "device", "default", "$device.alias-id"
  ]

  test-cli.run-gold "200_install"
      "Install a container"
      [
        "device", "container", "install", "hello", hello-path
      ]

  test-cli.run-gold "220_uninstall"
      "Uninstall a container"
      [
        "device", "container", "uninstall", "hello"
      ]

  test-cli.run-gold "230_uninstall_non_existing"
      --expect-exit-1
      "Uninstall a non-existing container"
      [
        "device", "container", "uninstall", "hello"
      ]

  // Force allows uninstalling a container that is not installed.
  test-cli.run-gold "240_uninstall_non_existing_force"
      "Uninstall a non-existing container with force"
      [
        "device", "container", "uninstall", "hello", "--force"
      ]

  test-cli.ensure-available-artemis-service
      --sdk-version=TEST-SDK-VERSION
      --artemis-version=TEST-ARTEMIS-VERSION

  pod-spec := deep-copy_ INITIAL-POD-SPECIFICATION

  pod-spec["sdk-version"] = TEST-SDK-VERSION
  pod-spec["artemis-version"] = TEST-ARTEMIS-VERSION

  pod-spec["connections"] = [
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
  pod-spec["containers"] = {
    "hello": {
      "entrypoint": "hello.toit"
    }
  }

  spec-file := "$tmp-dir/test.json"
  pod-file := "$tmp-dir/test.pod"
  write-json-to-file spec-file pod-spec

  test-cli.run [
    "pod", "create", spec-file, "-o", pod-file
  ]

  test-cli.run [
    "device", "update", "--local", pod-file
  ]

  device.synchronize
  device.flash
  device.reboot
  device.report-state

  // Hello is now a required container.
  test-cli.run-gold "300_uninstall_required"
      "Can't uninstall required container without force"
      --expect-exit-1
      [
        "device", "container", "uninstall", "hello"
      ]

  // Works with force.
  test-cli.run-gold "310_uninstall_required_force"
      "Can uninstall required container with force"
      [
        "device", "container", "uninstall", "hello", "--force"
      ]
