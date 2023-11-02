// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import expect show *

import .qemu
import .utils

HELLO-WORLD-CODE ::= """
main: print "hello world"
"""

main args/List:
  with-fleet --args=args --count=0: | test-cli/TestCli _ fleet-dir/string |
    qemu-data := build-qemu-image
        --test-cli=test-cli
        --args=args
        --fleet-dir=fleet-dir
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
    run-test test-cli qemu-data

run-test test-cli/TestCli qemu-data/Map:
  tmp-dir := test-cli.tmp-dir
  ui := TestUi --no-quiet

  image-path := qemu-data["image-path"]
  device-id := qemu-data["device-id"]

  test-device := test-cli.start-device
      --alias-id=device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=device-id
      --qemu-image=image-path

  print "Starting to look for 'hello world' and 'INFO: synchronized'."
  pos := test-device.wait-for "hello world" --start-at=0
  print "Found 'hello world'."
  test-device.wait-for "INFO: synchronized" --start-at=pos
  print "Found 'INFO: synchronized'."
