// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import artemis.cli.fleet
import expect show *
import .utils

DEVICE_COUNT ::= 3

main args:
  with_fleet --count=DEVICE_COUNT --args=args: | test_cli/TestCli _ fleet_dir/string |
    run_test test_cli fleet_dir

run_test test_cli/TestCli fleet_dir/string:
  test_cli.run_gold "110-list-groups"
      "List the initial groups"
      [
        "--fleet-root", fleet_dir,
        "fleet", "group", "list"
      ]

  test_cli.run_gold "120-add-group-no-force"
      "Add a group without force"
      --expect_exit_1
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "create", "test-group",
          "--template", "default",
      ]

  test_cli.run_gold "121-add-group"
      "Add a group"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "create", "test-group",
          "--template", "default",
          "--force",  // Force, since the pod doesn't actually exist.
      ]
  groups := test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 2 groups.size
  expect_equals "default" groups[0]["name"]
  expect_equals "test-group" groups[1]["name"]
  expect_equals groups[0]["pod"] groups[1]["pod"]

  test_cli.run_gold "130-remove-group"
      "Remove a group"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "remove", "test-group"
      ]
  groups = test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 1 groups.size
  expect_equals "default" groups[0]["name"]

  test_cli.run_gold "122-add-group-with-pod"
      "Add a group with a pod"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "create", "test-group",
          "--pod", "unknown@pod",
          "--force",
      ]
  groups = test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 2 groups.size
  expect_equals "default" groups[0]["name"]
  expect_equals "test-group" groups[1]["name"]
  expect_equals "unknown@pod" groups[1]["pod"]

  test_cli.run_gold "123-add-group-from-group"
      "Add a group from a group"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "create", "test-group-2",
          "--template", "test-group",
          "--force",
      ]
  groups = test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 3 groups.size
  expect_equals "default" groups[0]["name"]
  expect_equals "test-group" groups[1]["name"]
  expect_equals "test-group-2" groups[2]["name"]
  expect_equals "unknown@pod" groups[1]["pod"]
  expect_equals "unknown@pod" groups[2]["pod"]

  // Can't add a group that already exists.
  test_cli.run_gold "124-add-group-already-exists"
      "Add a group that already exists"
      --expect_exit_1
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "create", "test-group",
          "--template", "default",
          "--force",
      ]

  // Test updating.
  test_cli.run_gold "140-update-group"
      "Update a group"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "update", "test-group",
          "--pod", "unknown@pod2",
          "--force",
      ]
  groups = test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 3 groups.size
  expect_equals "test-group" groups[1]["name"]
  expect_equals "unknown@pod2" groups[1]["pod"]

  // Update the name.
  test_cli.run_gold "141-update-group-name"
      "Update a group name"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "update", "test-group",
          "--name", "test-group-3",
          "--force",
      ]
  groups = test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 3 groups.size
  // The groups are sorted by name (with 'default' on top).
  expect_equals "default" groups[0]["name"]
  expect_equals "test-group-2" groups[1]["name"]
  expect_equals "test-group-3" groups[2]["name"]

  // Change both at the same time.
  test_cli.run_gold "142-update-group-name-and-pod"
      "Update a group name and pod"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "update", "test-group-3",
          "--name", "test-group-4",
          "--pod", "unknown2@tag",
          "--force",
      ]
  groups = test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 3 groups.size
  expect_equals "default" groups[0]["name"]
  expect_equals "test-group-2" groups[1]["name"]
  expect_equals "test-group-4" groups[2]["name"]
  expect_equals "unknown2@tag" groups[2]["pod"]

  test_cli.run_gold "143-update-default-group-name"
      "Update the default group name"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "update", "default",
          "--name", "test-group-5",
          "--force",
      ]
  groups = test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 3 groups.size
  expect_equals "test-group-5" groups[2]["name"]

  // Check that the devices now correctly reference the new group name.
  devices_file := fleet.Fleet.load_devices_file fleet_dir --ui=TestUi
  expect_equals DEVICE_COUNT devices_file.devices.size
  devices_file.devices.do: | device/fleet.DeviceFleet |
    expect_equals "test-group-5" device.group

  // Rename it back, so that the rest of the tests continue to work.
  test_cli.run [
        "--fleet-root", fleet_dir,
        "fleet", "group", "update", "test-group-5",
        "--name", "default",
        "--force",
      ]

  devices_file = fleet.Fleet.load_devices_file fleet_dir --ui=TestUi
  expect_equals DEVICE_COUNT devices_file.devices.size
  devices_file.devices.do: | device/fleet.DeviceFleet |
    expect_equals "default" device.group

  // Can't rename a group to an existing group.
  test_cli.run_gold "144-update-group-name-already-exists"
      "Update a group name to an existing group"
      --expect_exit_1
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "update", "test-group-2",
          "--name", "test-group-4",
          "--force",
      ]

  // Can't rename a group that doesn't exist.
  test_cli.run_gold "145-update-group-name-doesnt-exist"
      "Update a group name that doesn't exist"
      --expect_exit_1
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "update", "test-group-5",
          "--name", "test-group-6",
          "--force",
      ]

  test_cli.run_gold "146-list-groups"
      "List groups"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "list",
      ]

  test_cli.run_gold "147-update-tags"
      "Update the tags of all pods"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "update", "default", "test-group-2", "test-group-4",
          "--tag", "new-tag",
          "--force",
      ]
  groups = test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 3 groups.size
  expect_equals "my-pod@new-tag" groups[0]["pod"]
  expect_equals "unknown@new-tag" groups[1]["pod"]
  expect_equals "unknown2@new-tag" groups[2]["pod"]

  test_cli.run_gold "148-rename-multi"
      "Can't rename multiple groups at once"
      --expect_exit_1
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "update", "test-group-2", "test-group-4",
          "--name", "test-group-5",
          "--force",
      ]

  test_cli.run_gold "149-update-pod-multi"
      "Update the pod of multiple groups"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "update", "test-group-2", "test-group-4",
          "--pod", "multi@tag",
          "--force",
      ]
  groups = test_cli.run --json ["--fleet-root", fleet_dir, "fleet", "group", "list"]
  expect_equals 3 groups.size
  expect_equals "my-pod@new-tag" groups[0]["pod"]
  expect_equals "multi@tag" groups[1]["pod"]
  expect_equals "multi@tag" groups[2]["pod"]

  // Move all devices from the default group to the test-group-2 group.
  test_cli.run_gold "150-move-devices"
      "Move all devices from the default group to the test-group-2 group"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "move", "--group", "default", "--to", "test-group-2",
      ]

  // We can't remove the test-group-2 anymore.
  test_cli.run_gold "151-remove-group-with-devices"
      "Remove a group with devices"
      --expect_exit_1
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "remove", "test-group-2",
      ]

  device_file := fleet.Fleet.load_devices_file fleet_dir --ui=TestUi
  fleet_devices := device_file.devices

  // Move individual devices to group-4.
  test_cli.run_gold "152-move-devices-individually"
      "Move individual devices to group-4"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "move", "--to", "test-group-4",
          "$((fleet_devices[0] as fleet.DeviceFleet).id)",
          "$((fleet_devices[1] as fleet.DeviceFleet).name)",
      ]

  // Move multiple groups to the default group.
  test_cli.run_gold "153-move-groups"
      "Move multiple groups to the default group"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "move", "--to", "default",
          "--group", "test-group-2",
          "--group", "test-group-4",
      ]

  // We can now remove the test groups again (since they don't have any devices anymore).
  test_cli.run_gold "154-remove-group"
      "Remove a group"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "remove", "test-group-2",
      ]

  test_cli.run_gold "155-remove-group"
      "Remove a group"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "remove", "test-group-4",
      ]

  // Create a new group and move all devices to it, so we can test removing the default group.
  test_cli.run ["--fleet-root", fleet_dir, "fleet", "group", "create", "test-group-5", "--force"]
  test_cli.run ["--fleet-root", fleet_dir, "fleet", "group", "move", "--to", "test-group-5", "--group", "default"]

  test_cli.run_gold "156-remove-default-group"
      "Remove the default group"
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "remove", "default"
      ]

  // It's an error to move devices to a group that doesn't exist.
  test_cli.run_gold "170-move-to-non-existing-group"
      "Move devices to a non-existing group"
      --expect_exit_1
      [
          "--fleet-root", fleet_dir,
          "fleet", "group", "move",
          "--to", "default",
          "--group", "test-group-5"
      ]
