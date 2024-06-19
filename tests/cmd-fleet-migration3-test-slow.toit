// Copyright (C) 2024 Toitware ApS.

import expect show *
import system
import .utils

main args:
  // We can't create host-devices on Windows.
  if system.platform == system.PLATFORM-WINDOWS: return

  with-fleet --args=args: | fleet/TestFleet |
    fleet.upload-pod "initial" --format="tar"

    device := fleet.create-host-device "device" --start
    device2 := fleet.create-host-device "device2" --start

    device.wait-for-synchronized
    device2.wait-for-synchronized
    device2.stop

    // Create a migration broker.
    broker := fleet.start-broker "migration-broker"

    // Migrate to this broker.
    fleet.run ["fleet", "migration", "start", "--broker", broker.name]

    // Check that we can update all devices.
    pod-id := fleet.upload-pod "pod1" --format="tar"
    fleet.update-device-output-positions

    // Start by updating device2 (which is stopped).
    // We will check that it hasn't changed after device1 is updated.
    fleet.run ["device", "update", "-d", "$device2.id", "$pod-id"]

    fleet.run ["device", "update", "-d", "$device.id", "$pod-id"]
    // Wait for the device to be on the new pod.
    device.wait-to-be-on-pod pod-id
    // Check that the device is on the new broker.
    expect-equals broker.name device.get-current-broker

    // Check that device2 is still on the old broker.
    expect-not-equals broker.name device2.get-current-broker

    // Update the device2 again.
    pod-id2 := fleet.upload-pod "pod2" --format="tar"
    fleet.run ["device", "update", "-d", "$device2.id", "$pod-id2"]
    // Start the device2. It should move to the new pod on the new broker.
    device2.start
    device2.wait-to-be-on-pod pod-id2
    expect-equals broker.name device2.get-current-broker
