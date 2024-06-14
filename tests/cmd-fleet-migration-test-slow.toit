// Copyright (C) 2024 Toitware ApS.

import expect show *
import .migration
import .utils

main args:
  with-migration-test --args=args: | test/MigrationTest |
    // To create a device we need to have an uploaded pod.
    test.upload-pod "initial"
    // Three devices.
    // The first one keeps running.
    // The second is stopped.
    // The third is not started (for the first migration).
    initial1/MigrationDevice := test.create-device "initial1" --start
    initial2/MigrationDevice := test.create-device "initial2" --start
    // The third device is not started.
    never-started/MigrationDevice := test.create-device "never-started" --no-start

    // Spin up the new1 broker.
    new1 := test.start-broker "new1"

    // Start the migration.
    // Starting the migration doesn't do anything yet.
    // We will need to roll out a new version of the pod.
    test.run ["fleet", "migration", "start", "--broker", new1.name]

    // Make sure that our check for finished migrations work.
    test.check-no-migration-stop

    // Upload a new pod to the new broker. (Still doesn't affect the devices).
    test.upload-pod "new1-pod"

    // Create a new device on this broker. The device is unknown to older brokers.
    device-new1 := test.create-device "device-new1" --start

    test.run-gold --ignore-spacing "010-before-roll-out"
          "initial1-2 still on old; never-started (never seen) assumed to be on new1"
          ["fleet", "status", "--include-never-seen"]

    initial2.stop

    test.run ["fleet", "roll-out"]

    status := initial1.wait-to-be-on-broker new1
    expect-not-equals new1.name (initial2.get-current-broker --status=status)

    // We still aren't allowed to stop the migration.
    test.check-no-migration-stop

    // Start initial2 up again.
    initial2.start
    initial2.wait-to-be-on-broker new1

    // Stop all devices and let them run again until synchronization.
    // We want them still to be on new1.
    all-active-devices := [initial1, initial2, device-new1]
    all-active-devices.do: | device/MigrationDevice |
      device.stop
      device.update-output-pos
      device.start

    all-active-devices.do: | device/MigrationDevice |
      device.wait-for-synchronization

    status = test.get-status
    all-active-devices.do: | device/MigrationDevice |
      expect-equals new1.name (device.get-current-broker --status=status)

    // Now we can stop the migration.
    // Note that device 'never-started' is not on the new broker and would not be
    // able to recover.
    test.run ["fleet", "migration", "stop"]
    test.stop-main-broker

    // Do one more migration to ensure that none of the devices is somehow
    // accessing the old broker.

    pod-id := test.upload-pod "after-pod"
    test.run ["fleet", "roll-out"]

    all-active-devices.do: | device/MigrationDevice |
      device.wait-to-be-on-pod pod-id

    new1.close
