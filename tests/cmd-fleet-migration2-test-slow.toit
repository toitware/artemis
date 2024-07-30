// Copyright (C) 2024 Toitware ApS.

import expect show *
import system
import .utils

main args:
  // We can't create host-devices on Windows.
  if system.platform == system.PLATFORM-WINDOWS: return

  with-fleet --args=args: | fleet/TestFleet |
    counter := 0
    stopped-devices := []
    running-devices := []

    fleet.upload-pod "pod-$(counter++)" --format="tar"

    migration-brokers := []
    3.repeat: | i/int |
      // ---  On the *old* broker  ---.
      // Create two devices. One that is running and one that will be
      // stopped after synchronization.
      running := fleet.create-host-device "running-$(counter++)" --start
      stopped := fleet.create-host-device "stopped-$(counter++)" --start
      running.wait-for-synchronized
      stopped.wait-for-synchronized
      stopped.stop
      running-devices.add running
      stopped-devices.add stopped

      // Spin up a new broker.
      broker := fleet.start-broker "broker-$i"
      migration-brokers.add broker

      // Migrate to this broker.
      fleet.run ["fleet", "migration", "start", "--broker", broker.name]

      // Test that we don't accidentally create cycles.
      // After running through the brokers we are back at the newest broker.
      migration-brokers.do: | other-broker/MigrationBroker |
        fleet.run ["fleet", "migration", "start", "--broker", other-broker.name]

      // ---  On the new broker  ---.
      fleet.upload-pod "pod-$(counter++)" --format="tar"
      fleet.run ["fleet", "roll-out"]

      status/List? := null
      running-devices.do: | device/TestDevice |
        status = device.wait-to-be-on-broker broker --status=status

      stopped-devices.do: | device/TestDevice |
        expect-not-equals broker.name (device.get-current-broker --status=status)

      fleet.check-no-migration-stop

    // Start the stopped devices and bring them to the new broker.
    stopped-devices.do: | device/TestDevice |
      device.start
      device.wait-to-be-on-broker migration-brokers.last

    // Check that we can update all devices.
    pod-id := fleet.upload-pod "almost-final-pod" --format="tar"
    fleet.update-device-output-positions
    fleet.run ["fleet", "roll-out"]

    all-devices := running-devices + stopped-devices
    status/List? := null
    // Wait for all devices to be on the new pod.
    all-devices.do: | device/TestDevice |
      status = device.wait-to-be-on-pod pod-id --status=status

    // Stop the migration.
    fleet.run ["fleet", "migration", "stop"]
    fleet.tester.stop-main-broker
    migration-brokers[..migration-brokers.size - 1].do: | broker/MigrationBroker |
      broker.close

    // Check that we can do a final migration.
    pod-id = fleet.upload-pod "final-pod" --format="tar"
    fleet.update-device-output-positions
    fleet.run ["fleet", "roll-out"]

    // Wait for all devices to be on the new pod.
    all-devices.do: | device/TestDevice |
      device.wait-to-be-on-pod pod-id

    migration-brokers.last.close
