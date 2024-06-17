// Copyright (C) 2024 Toitware ApS.

import expect show *
import .utils

main args:
  with-fleet --args=args: | fleet/TestFleet |
    // Spin up a few more brokers.
    migration-brokers := List 3: | i/int |
      broker-name := "broker-$i"
      fleet.start-broker broker-name

    counter := 0
    stopped-devices := []
    running-devices := []
    last-broker/MigrationBroker? := null

    fleet.upload-pod "pod-$(counter++)" --format="tar"
    migration-brokers.do: | broker/MigrationBroker |
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

      // Migrate to this broker.
      fleet.run ["fleet", "migration", "start", "--broker", broker.name]

      // ---  On the new broker  ---.
      fleet.upload-pod "pod-$(counter++)" --format="tar"
      fleet.run ["fleet", "roll-out"]

      status/List? := null
      running-devices.do: | device/TestDevice |
        status = device.wait-to-be-on-broker broker --status=status

      stopped-devices.do: | device/TestDevice |
        expect-not-equals broker.name (device.get-current-broker --status=status)

      fleet.check-no-migration-stop
      last-broker = broker

    // Start the stopped devices and bring them to the new broker.
    stopped-devices.do: | device/TestDevice |
      device.start
      device.wait-to-be-on-broker last-broker

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
    fleet.test-cli.stop-main-broker
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
