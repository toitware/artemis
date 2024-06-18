// Copyright (C) 2024 Toitware ApS.

import expect show *
import .utils

main args:
  with-fleet --args=args: | fleet/TestFleet |
    // To create a device we need to have an uploaded pod.
    fleet.upload-pod "initial" --format="tar"
    // Three devices.
    // The first one keeps running.
    // The second is stopped.
    // The third is not started (for the first migration).
    initial1/TestDevice := fleet.create-host-device "initial1" --start
    initial2/TestDevice := fleet.create-host-device "initial2" --start
    // The third device is not started.
    never-started/TestDevice := fleet.create-host-device "never-started" --no-start

    // Spin up the new1 broker.
    new1 := fleet.start-broker "new1"

    // Start the migration.
    // Starting the migration doesn't do anything yet.
    // We will need to roll out a new version of the pod.
    fleet.run ["fleet", "migration", "start", "--broker", new1.name]

    // Make sure that our check for finished migrations work.
    fleet.check-no-migration-stop

    // Upload a new pod to the new broker. (Still doesn't affect the devices).
    fleet.upload-pod "new1-pod" --format="tar"

    // Create a new device on this broker. The device is unknown to older brokers.
    device-new1 := fleet.create-host-device "device-new1" --start

    fleet.run-gold --ignore-spacing "010-before-roll-out"
          "initial1-2 still on old; never-started (never seen) assumed to be on new1"
          ["fleet", "status", "--include-never-seen"]

    initial2.stop

    fleet.run ["fleet", "roll-out"]

    status := initial1.wait-to-be-on-broker new1
    expect-not-equals new1.name (initial2.get-current-broker --status=status)

    // We still aren't allowed to stop the migration.
    fleet.check-no-migration-stop

    // Start initial2 up again.
    initial2.start
    initial2.wait-to-be-on-broker new1

    // Stop all devices and let them run again until synchronization.
    // We want them still to be on new1.
    all-active-devices := [initial1, initial2, device-new1]
    all-active-devices.do: | device/TestDevice |
      device.stop
      device.update-output-pos
      device.start

    all-active-devices.do: | device/TestDevice |
      device.wait-for-synchronized

    status = fleet.get-status
    all-active-devices.do: | device/TestDevice |
      expect-equals new1.name (device.get-current-broker --status=status)

    // Now we can stop the migration.
    // Note that device 'never-started' is not on the new broker and would not be
    // able to recover.
    fleet.run ["fleet", "migration", "stop"]
    fleet.test-cli.stop-main-broker

    // Do one more migration to ensure that none of the devices is somehow
    // accessing the old broker.

    pod-id := fleet.upload-pod "after-pod" --format="tar"
    fleet.run ["fleet", "roll-out"]

    all-active-devices.do: | device/TestDevice |
      device.wait-to-be-on-pod pod-id

    new1.close
