// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import expect show *
import system

import .cli-device-extract
import .utils

HELLO-WORLD-CODE ::= """
main: print "hello world"
"""

main args/List:
  // We can't create host-devices on Windows.
  if system.platform == system.PLATFORM-WINDOWS: return

  with-fleet --args=args --count=0: | fleet/TestFleet |
    host-config := create-extract-device
        --format="tar"
        --fleet=fleet
        --files={
          "hello.toit": HELLO-WORLD-CODE,
        }
        --pod-spec={
          "containers": {
            "hello": {
              "entrypoint": "hello.toit",
            },
          },
        }
    run-test fleet.tester host-config

run-test tester/Tester config/TestDeviceConfig:
  tmp-dir := tester.tmp-dir
  ui := TestUi --no-quiet

  device-id := config.device-id

  test-device := tester.create-device
      --alias-id=device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=device-id
      --device-config=config
  test-device.start

  print "Starting to look for 'hello world' and 'INFO: synchronized'."
  pos := test-device.wait-for "hello world" --start-at=0
  print "Found 'hello world'."
  test-device.wait-for-synchronized --start-at=pos
  print "Found 'INFO: synchronized'."
  test-device.close
