// Copyright (C) 2024 Toitware ApS.

import expect show *
import .migration
import .utils

main args:
  with-migration-test --args=args: | test/MigrationTest |
    // Spin up a few more brokers.
    migration-brokers := List 3: | i/int |
      broker-name := "broker-$i"
      test.start-broker broker-name

    counter := 0
    stopped-devices := []
    running-devices := []
    last-broker/MigrationBroker? := null

    test.upload-pod "pod-$(counter++)"
    migration-brokers.do: | broker/MigrationBroker |
      // ---  On the *old* broker  ---.
      // Create two devices. One that is running and one that will be
      // stopped after synchronization.
      running := test.create-device "running-$(counter++)" --start
      stopped := test.create-device "stopped-$(counter++)" --start
      running.wait-for-synchronization
      stopped.wait-for-synchronization
      stopped.stop
      running-devices.add running
      stopped-devices.add stopped

      // Migrate to this broker.
      test.run ["fleet", "migration", "start", "--broker", broker.name]

      // ---  On the new broker  ---.
      test.upload-pod "pod-$(counter++)"
      test.run ["fleet", "roll-out"]

      status/List? := null
      running-devices.do: | device/MigrationDevice |
        status = device.wait-to-be-on-broker broker --status=status

      stopped-devices.do: | device/MigrationDevice |
        expect-not-equals broker.name (device.get-current-broker --status=status)

      test.check-no-migration-stop
      last-broker = broker

    // Start the stopped devices and bring them to the new broker.
    stopped-devices.do: | device/MigrationDevice |
      device.start
      device.wait-to-be-on-broker last-broker

    // Check that we can update all devices.
    pod-id := test.upload-pod "almost-final-pod"
    test.update-device-output-positions
    test.run ["fleet", "roll-out"]

    all-devices := running-devices + stopped-devices
    status/List? := null
    // Wait for all devices to be on the new pod.
    all-devices.do: | device/MigrationDevice |
      status = device.wait-to-be-on-pod pod-id --status=status

    // Stop the migration.
    test.run ["fleet", "migration", "stop"]
    test.stop-main-broker
    migration-brokers[..migration-brokers.size - 1].do: | broker/MigrationBroker |
      broker.close

    // Check that we can do a final migration.
    pod-id = test.upload-pod "final-pod"
    test.update-device-output-positions
    test.run ["fleet", "roll-out"]

    // Wait for all devices to be on the new pod.
    all-devices.do: | device/MigrationDevice |
      device.wait-to-be-on-pod pod-id

    migration-brokers.last.close
