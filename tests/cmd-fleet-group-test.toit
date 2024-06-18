// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import artemis.cli.fleet as fleet-lib
import expect show *
import .utils

DEVICE-COUNT ::= 3

main args:
  with-fleet --count=DEVICE-COUNT --args=args: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  fleet.run-gold "110-list-groups"
      "List the initial groups"
      [
        "fleet", "group", "list"
      ]

  fleet.run-gold "120-add-group-no-force"
      "Add a group without force"
      --expect-exit-1
      [
          "fleet", "group", "add", "test-group",
          "--template", "default",
      ]

  fleet.run-gold "121-add-group"
      "Add a group"
      [
          "fleet", "group", "add", "test-group",
          "--template", "default",
          "--force",  // Force, since the pod doesn't actually exist.
      ]
  groups := fleet.run --json ["fleet", "group", "list"]
  expect-equals 2 groups.size
  expect-equals "default" groups[0]["name"]
  expect-equals "test-group" groups[1]["name"]
  expect-equals groups[0]["pod"] groups[1]["pod"]

  fleet.run-gold "130-remove-group"
      "Remove a group"
      [
          "fleet", "group", "remove", "test-group"
      ]
  groups = fleet.run --json ["fleet", "group", "list"]
  expect-equals 1 groups.size
  expect-equals "default" groups[0]["name"]

  fleet.run-gold "122-add-group-with-pod"
      "Add a group with a pod"
      [
          "fleet", "group", "add", "test-group",
          "--pod", "unknown@pod",
          "--force",
      ]
  groups = fleet.run --json ["fleet", "group", "list"]
  expect-equals 2 groups.size
  expect-equals "default" groups[0]["name"]
  expect-equals "test-group" groups[1]["name"]
  expect-equals "unknown@pod" groups[1]["pod"]

  fleet.run-gold "123-add-group-from-group"
      "Add a group from a group"
      [
          "fleet", "group", "add", "test-group-2",
          "--template", "test-group",
          "--force",
      ]
  groups = fleet.run --json ["fleet", "group", "list"]
  expect-equals 3 groups.size
  expect-equals "default" groups[0]["name"]
  expect-equals "test-group" groups[1]["name"]
  expect-equals "test-group-2" groups[2]["name"]
  expect-equals "unknown@pod" groups[1]["pod"]
  expect-equals "unknown@pod" groups[2]["pod"]

  // Can't add a group that already exists.
  fleet.run-gold "124-add-group-already-exists"
      "Add a group that already exists"
      --expect-exit-1
      [
          "fleet", "group", "add", "test-group",
          "--template", "default",
          "--force",
      ]

  // Test updating.
  fleet.run-gold "140-update-group"
      "Update a group"
      [
          "fleet", "group", "update", "test-group",
          "--pod", "unknown@pod2",
          "--force",
      ]
  groups = fleet.run --json ["fleet", "group", "list"]
  expect-equals 3 groups.size
  expect-equals "test-group" groups[1]["name"]
  expect-equals "unknown@pod2" groups[1]["pod"]

  // Update the name.
  fleet.run-gold "141-update-group-name"
      "Update a group name"
      [
          "fleet", "group", "update", "test-group",
          "--name", "test-group-3",
          "--force",
      ]
  groups = fleet.run --json ["fleet", "group", "list"]
  expect-equals 3 groups.size
  // The groups are sorted by name (with 'default' on top).
  expect-equals "default" groups[0]["name"]
  expect-equals "test-group-2" groups[1]["name"]
  expect-equals "test-group-3" groups[2]["name"]

  // Change both at the same time.
  fleet.run-gold "142-update-group-name-and-pod"
      "Update a group name and pod"
      [
          "fleet", "group", "update", "test-group-3",
          "--name", "test-group-4",
          "--pod", "unknown2@tag",
          "--force",
      ]
  groups = fleet.run --json ["fleet", "group", "list"]
  expect-equals 3 groups.size
  expect-equals "default" groups[0]["name"]
  expect-equals "test-group-2" groups[1]["name"]
  expect-equals "test-group-4" groups[2]["name"]
  expect-equals "unknown2@tag" groups[2]["pod"]

  fleet.run-gold "143-update-default-group-name"
      "Update the default group name"
      [
          "fleet", "group", "update", "default",
          "--name", "test-group-5",
          "--force",
      ]
  groups = fleet.run --json ["fleet", "group", "list"]
  expect-equals 3 groups.size
  expect-equals "test-group-5" groups[2]["name"]

  // Check that the devices now correctly reference the new group name.
  devices-file := fleet-lib.FleetWithDevices.load-devices-file fleet.fleet-dir --ui=TestUi
  expect-equals DEVICE-COUNT devices-file.devices.size
  devices-file.devices.do: | device/fleet-lib.DeviceFleet |
    expect-equals "test-group-5" device.group

  // Rename it back, so that the rest of the tests continue to work.
  fleet.run [
        "fleet", "group", "update", "test-group-5",
        "--name", "default",
        "--force",
      ]

  devices-file = fleet-lib.FleetWithDevices.load-devices-file fleet.fleet-dir --ui=TestUi
  expect-equals DEVICE-COUNT devices-file.devices.size
  devices-file.devices.do: | device/fleet-lib.DeviceFleet |
    expect-equals "default" device.group

  // Can't rename a group to an existing group.
  fleet.run-gold "144-update-group-name-already-exists"
      "Update a group name to an existing group"
      --expect-exit-1
      [
          "fleet", "group", "update", "test-group-2",
          "--name", "test-group-4",
          "--force",
      ]

  // Can't rename a group that doesn't exist.
  fleet.run-gold "145-update-group-name-doesnt-exist"
      "Update a group name that doesn't exist"
      --expect-exit-1
      [
          "fleet", "group", "update", "test-group-5",
          "--name", "test-group-6",
          "--force",
      ]

  fleet.run-gold "146-list-groups"
      "List groups"
      [
          "fleet", "group", "list",
      ]

  fleet.run-gold "147-update-tags"
      "Update the tags of all pods"
      [
          "fleet", "group", "update", "default", "test-group-2", "test-group-4",
          "--tag", "new-tag",
          "--force",
      ]
  groups = fleet.run --json ["fleet", "group", "list"]
  expect-equals 3 groups.size
  expect-equals "my-pod@new-tag" groups[0]["pod"]
  expect-equals "unknown@new-tag" groups[1]["pod"]
  expect-equals "unknown2@new-tag" groups[2]["pod"]

  fleet.run-gold "148-rename-multi"
      "Can't rename multiple groups at once"
      --expect-exit-1
      [
          "fleet", "group", "update", "test-group-2", "test-group-4",
          "--name", "test-group-5",
          "--force",
      ]

  fleet.run-gold "149-update-pod-multi"
      "Update the pod of multiple groups"
      [
          "fleet", "group", "update", "test-group-2", "test-group-4",
          "--pod", "multi@tag",
          "--force",
      ]
  groups = fleet.run --json ["fleet", "group", "list"]
  expect-equals 3 groups.size
  expect-equals "my-pod@new-tag" groups[0]["pod"]
  expect-equals "multi@tag" groups[1]["pod"]
  expect-equals "multi@tag" groups[2]["pod"]

  // Move all devices from the default group to the test-group-2 group.
  fleet.run-gold "150-move-devices"
      "Move all devices from the default group to the test-group-2 group"
      [
          "fleet", "group", "move", "--group", "default", "--to", "test-group-2",
      ]

  // We can't remove the test-group-2 anymore.
  fleet.run-gold "151-remove-group-with-devices"
      "Remove a group with devices"
      --expect-exit-1
      [
          "fleet", "group", "remove", "test-group-2",
      ]

  device-file := fleet-lib.FleetWithDevices.load-devices-file fleet.fleet-dir --ui=TestUi
  fleet-devices := device-file.devices

  // Move individual devices to group-4.
  fleet.run-gold "152-move-devices-individually"
      "Move individual devices to group-4"
      [
          "fleet", "group", "move", "--to", "test-group-4",
          "$((fleet-devices[0] as fleet-lib.DeviceFleet).id)",
          "$((fleet-devices[1] as fleet-lib.DeviceFleet).name)",
      ]

  // Move multiple groups to the default group.
  fleet.run-gold "153-move-groups"
      "Move multiple groups to the default group"
      [
          "fleet", "group", "move", "--to", "default",
          "--group", "test-group-2",
          "--group", "test-group-4",
      ]

  // We can now remove the test groups again (since they don't have any devices anymore).
  fleet.run-gold "154-remove-group"
      "Remove a group"
      [
          "fleet", "group", "remove", "test-group-2",
      ]

  fleet.run-gold "155-remove-group"
      "Remove a group"
      [
          "fleet", "group", "remove", "test-group-4",
      ]

  // Create a new group and move all devices to it, so we can test removing the default group.
  fleet.run ["fleet", "group", "add", "test-group-5", "--force"]
  fleet.run ["fleet", "group", "move", "--to", "test-group-5", "--group", "default"]

  fleet.run-gold "156-remove-default-group"
      "Remove the default group"
      [
          "fleet", "group", "remove", "default"
      ]

  // It's an error to move devices to a group that doesn't exist.
  fleet.run-gold "170-move-to-non-existing-group"
      "Move devices to a non-existing group"
      --expect-exit-1
      [
          "fleet", "group", "move",
          "--to", "default",
          "--group", "test-group-5"
      ]

  fleet.run-gold "180-no-add-existing-device"
      "Can't add a device to a group that doesn't exist"
      --expect-exit-1
      [
          "fleet", "add-existing-device", "--group", "does-not-exist", "$TEST-DEVICE-UUID",
      ]

  fleet.run-gold "181-no-add-existing-device-default"
      "Can't add a device to default group that doesn't exist"
      --expect-exit-1
      [
          "fleet", "add-existing-device", "$TEST-DEVICE-UUID",
      ]

  fleet.run-gold "182-no-create-identity"
      "Can't create an identity for a group that doesn't exist"
      --expect-exit-1
      [
          "fleet", "add-devices", "--group", "does-not-exist", "1",
      ]

  fleet.run-gold "183-no-create-identity-default"
      "Can't create an identity for default group that doesn't exist"
      --expect-exit-1
      [
          "fleet", "add-devices", "1",
      ]
