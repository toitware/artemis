// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import expect show *

import .cli-device-extract
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
  with-fleet --args=args --count=0: | fleet/TestFleet |
    qemu-data := create-extract-device
        --format="qemu"
        --fleet=fleet
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
    run-test fleet.test-cli qemu-data

run-test test-cli/TestCli qemu-data/TestDeviceConfig:
  tmp-dir := test-cli.tmp-dir
  ui := TestUi --no-quiet

  device-id := qemu-data.device-id

  test-device := test-cli.create-device
      --alias-id=device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=device-id
      --device-config=qemu-data
  test-device.start

  print "Starting to look for 'hello world'."
  pos := test-device.wait-for "hello world" --start-at=0
  pos = test-device.wait-for "wakeup reason: Trigger - boot" --start-at=pos
  pos = test-device.wait-for "triggers: [Trigger - boot]" --start-at=pos
  pos = test-device.wait-for "wakeup reason: Trigger - interval 1s" --start-at=pos
  // The triggers have been reset.
  pos = test-device.wait-for "triggers: [Trigger - boot]" --start-at=pos
  test-device.close
