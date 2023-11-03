// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import expect show *

import .qemu
import .utils

TEST-CODE ::= """
import artemis-pkg.artemis

main:
  print "hello world"
  print "wakeup reason: \$artemis.Container.current.trigger"
  print "triggers: \$artemis.Container.current.triggers"

  artemis.Container.current.set-next-start-triggers [
    artemis.TriggerInterval (Duration --s=1)
  ]
"""

NO-SLEEP-CODE ::= """
// Make sure we don't go into deep sleep.
main:
  sleep (Duration --h=1)
"""

main args/List:
  with-fleet --args=args --count=0: | test-cli/TestCli _ fleet-dir/string |
    qemu-data := build-qemu-image
        --test-cli=test-cli
        --args=args
        --fleet-dir=fleet-dir
        --files={
          "test.toit": TEST-CODE,
          "no-sleep.toit": NO-SLEEP-CODE,
        }
        --pod-spec={
          "containers": {
            "hello": {
              "entrypoint": "test.toit",
            },
            "no-sleep": {
              "entrypoint": "no-sleep.toit",
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

  print "Starting to look for 'hello world'."
  pos := test-device.wait-for "hello world" --start-at=0
  pos = test-device.wait-for "wakeup reason: Trigger - boot" --start-at=pos
  pos = test-device.wait-for "triggers: [Trigger - boot]" --start-at=pos
  pos = test-device.wait-for "wakeup reason: Trigger - interval 1s" --start-at=pos
  // The triggers have been reset.
  pos = test-device.wait-for "triggers: [Trigger - boot]" --start-at=pos
