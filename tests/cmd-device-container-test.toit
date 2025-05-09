// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli.pod-specification show INITIAL-POD-SPECIFICATION
import artemis.cli.utils show write-json-to-file write-blob-to-file
import .utils

main args:
  with-fleet --args=args --count=1: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  tmp-dir := fleet.tester.tmp-dir

  device/FakeDevice := fleet.devices.values[0]
  device.report-state

  hello-path := "$tmp-dir/hello.toit"
  write-blob-to-file hello-path """
      main: print "hello world"
      """

  fleet.run [
    "device", "default", "$device.alias-id"
  ]

  fleet.run-gold "200_install"
      "Install a container"
      [
        "device", "container", "install", "hello", hello-path
      ]

  fleet.run-gold "220_uninstall"
      "Uninstall a container"
      [
        "device", "container", "uninstall", "hello"
      ]

  fleet.run-gold "230_uninstall_non_existing"
      --expect-exit-1
      "Uninstall a non-existing container"
      [
        "device", "container", "uninstall", "hello"
      ]

  // Force allows uninstalling a container that is not installed.
  fleet.run-gold "240_uninstall_non_existing_force"
      "Uninstall a non-existing container with force"
      [
        "device", "container", "uninstall", "hello", "--force"
      ]

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

  fleet.run [
    "pod", "create", spec-file, "-o", pod-file
  ]

  fleet.run [
    "device", "update", "--local", pod-file
  ]

  device.synchronize
  device.flash
  device.reboot
  device.report-state

  // Hello is now a required container.
  fleet.run-gold "300_uninstall_required"
      "Can't uninstall required container without force"
      --expect-exit-1
      [
        "device", "container", "uninstall", "hello"
      ]

  // Works with force.
  fleet.run-gold "310_uninstall_required_force"
      "Can uninstall required container with force"
      [
        "device", "container", "uninstall", "hello", "--force"
      ]
