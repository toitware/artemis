// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import uuid

import .utils_
import ..artemis
import ..config
import ..cache
import ..device
import ..firmware
import ..fleet
import ..pod_registry
import ..ui
import ..utils

create_fleet_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "fleet"
      --short_help="Manage multiple devices at the same time."
      --long_help="""
        The 'fleet' command allows you to manage multiple devices at the same
        time. It can be used to create identity files and update multiple
        devices at the same time.

        The 'fleet roll-out' command can be used intuitively to send update
        requests to multiple devices.

        The remaining commands are designed to be used in a workflow, where
        multiple devices are flashed with the same pod. Frequently, flash stations
        are not connected to the Internet, so the 'fleet create-identities' and
        'pod create' commands are used to create the necessary files, which are
        then transferred to the flash station.

        A typical flashing workflow consists of:
        1. Create an Artemis pod using 'pod create'.
        2. Create identity files using 'fleet create-identities'.
        3. Transfer the pod and the identity files to the flash station.
        4. Flash the devices using 'serial flash'.
        """

  init_cmd := cli.Command "init"
      --long_help="""
        Initialize a fleet root.

        This command initializes a fleet root in a directory, so it can be
        used by the other fleet commands.

        The directory can be specified using the '--fleet-root' option.

        The fleet will be in the given organization id. If no organization id
        is given, the default organization is used.
        """
      --options=[
        OptionUuid "organization-id"
            --short_help="The organization to use."
      ]
      --run=:: init it config cache ui
  cmd.add init_cmd

  create_identities_cmd := cli.Command "create-identities"
      --long_help="""
        Create a specified number of identity files.

        Identity files describe a device, containing their ID and organization.
        For each written identity file, a device is provisioned in the Toit
        cloud.

        Use 'flash-station flash' to flash a device with an identity file and a
        specification or firmware image.

        This command requires the broker to be configured.
        This command requires Internet access.
        """
      --options=[
        cli.Option "output-directory"
            --type="directory"
            --short_help="Directory to write the identity files to."
            --default=".",
        cli.Option "group"
            --default=DEFAULT_GROUP
            --short_help="Add the devices to a group.",
      ]
      --aliases=[
        "provision",
      ]
      --rest=[
        cli.OptionInt "count"
            --short_help="Number of identity files to create."
            --required,
      ]
      --run=:: create_identities it config cache ui
  cmd.add create_identities_cmd

  update_cmd := cli.Command "update"
      --short_help="Deprecated alias for 'roll-out'."
      --options=[
        cli.Option "diff-base"
            --type="pod-file"
            --short_help="The base pod to use for diff-based updates."
            --multi,
      ]
      --run=::
        ui.warning "The 'fleet update' command is deprecated. Use 'fleet roll-out' instead."
        roll_out it config cache ui
  cmd.add update_cmd

  roll_out_cmd := cli.Command "roll-out"
      --aliases=[
        "rollout",
        "deploy"
      ]
      --long_help="""
        Roll out the fleet configuration to all devices in the fleet.

        If a device has no known state, patches for all base firmwares are
        created. If a device has reported its state, then only patches
        for the reported firmwares are created.

        If diff-bases are given, then the given pods are uploaded
        to the fleet's organization and used as diff bases for devices where
        the current state is not known.

        The most common use case for diff bases is when the current
        state of the device is not yet known because it never connected to
        the broker. The corresponding identity might not even be used yet.
        In this case, one of the diff bases should be the pod that will be
        (or was) used to flash the device.

        Note that diff-bases are only an optimization. Without them, the
        firmware update will still work, but will not be as efficient.
        """
      --options=[
        cli.Option "diff-base"
            --type="pod-file"
            --short_help="The base pod to use for diff-based updates."
            --multi,
      ]
      --run=:: roll_out it config cache ui
  cmd.add roll_out_cmd

  status_cmd := cli.Command "status"
      --long_help="""
        Show the status of the fleet.
        """
      --options=[
        cli.Flag "include-healthy"
            --short_help="Show healthy devices."
            --default=true,
        cli.Flag "include-never-seen"
            --short_help="Include devices that have never been seen."
            --default=false,
      ]
      --run=:: status it config cache ui
  cmd.add status_cmd

  add_device_cmd := cli.Command "add-device"
      --long_help="""
        Add an existing device to the fleet.

        This command adds an existing device to the fleet. The device must
        already be provisioned and be in the same organization as the fleet.

        Usually, this command is not needed. Devices are automatically added
        to the fleet when their identities are created.

        This command can be useful to migrate devices from one fleet to
        another, or to add devices that were created before fleets existed.
        """
      --options=[
        cli.Option "name"
            --short_help="The name of the device.",
        cli.Option "alias"
            --short_help="The alias of the device."
            --multi
            --split_commas,
        cli.Option "group"
            --default=DEFAULT_GROUP
            --short_help="Add the device to a group.",
      ]
      --rest=[
        OptionUuid "device-id"
            --short_help="The ID of the device to add."
            --required,
      ]
      --run=:: add_device it config cache ui
  cmd.add add_device_cmd

  group_cmd := cli.Command "group"
      --long_help="""
        Manage groups in the fleet.

        Groups are used to organize devices in the fleet. Devices can be
        added to groups when they are created, or later using the 'group move'
        command.
        """
  cmd.add group_cmd

  group_list_cmd := cli.Command "list"
      --short_help="List the groups in the fleet."
      --run=:: group_list it config cache ui
  group_cmd.add group_list_cmd

  group_create_cmd := cli.Command "create"
      --long_help="""
        Create a group in the fleet.

        If a pod reference is given, uses it for the new group.
        If a template is given, uses its pod reference for the new group.
        If neither a pod reference nor a template is given uses the default pod reference.
        """
      --options=[
        cli.Option "pod"
            --short_help="The pod reference to use for the group.",
        cli.Option "template"
            --short_help="The existing group that should be used as a template for the new group.",
        cli.Flag "force"
            --short_help="Create the group even if the pod doesn't exist."
            --short_name="f",
      ]
      --rest=[
        cli.Option "name"
            --short_help="The name of the new group."
            --required,
      ]
      --run=:: group_create it config cache ui
  group_cmd.add group_create_cmd

  group_update_cmd := cli.Command "update"
      --long_help="""
        Update one or several groups in the fleet.

        Updates the pod reference and/or name of the given groups. However,
        when using the '--name' flag only one group can be given.

        The new pod can be specified by a qualified pod-reference or by providing
        a new tag for the existing pod.
        """
      --options=[
        cli.Option "pod"
            --type="pod-reference"
            --short_help="The pod reference to use for the group.",
        cli.Option "name"
            --short_help="The new name of the group.",
        cli.Option "tag"
            --short_help="The tag to update the existing pod to.",
        cli.Flag "force"
            --short_help="Update the group even if the pod doesn't exist."
            --short_name="f",
      ]
      --rest=[
        cli.Option "group"
            --short_help="The name of the group to update."
            --required
            --multi,
      ]
      --examples=[
        cli.Example "Update groups 'g1' and 'g2' to use pods with tag 'v1.2'."
            --arguments="--tag=v1.2 g1 g2",
        cli.Example "Rename group 'g1' to 'g2'."
            --arguments="--name=g2 g1",
        cli.Example "Update group 'g1' to use pod 'my-pod#11'."
            --arguments="--pod=my-pod#11 g1",
        cli.Example "Update group 'g2' to use pod 'my-pod@latest'."
            --arguments="--pod=my-pod@latest g2",
      ]
      --run=:: group_update it config cache ui
  group_cmd.add group_update_cmd

  group_remove_cmd := cli.Command "remove"
      --short_help="Remove a group from the fleet."
      --rest=[
        cli.Option "group"
            --short_help="The name of the group to remove."
            --required,
      ]
      --run=:: group_remove it config cache ui
  group_cmd.add group_remove_cmd

  group_move_cmd := cli.Command "move"
      --short_help="Move devices between groups."
      --options=[
        cli.Option "to"
            --short_help="The group to move the devices to."
            --required,
        cli.Option "group"
            --short_help="A group to move the devices from."
            --multi,
      ]
      --rest=[
        cli.Option "device"
            --short_help="The ID, namer or alias of a device to move."
            --multi,
      ]
      --run=:: group_move it config cache ui
  group_cmd.add group_move_cmd

  return [cmd]

init parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root_flag := parsed["fleet-root"]
  organization_id := parsed["organization-id"]

  if not organization_id:
    default_organization_id := default_organization_from_config config
    if not default_organization_id:
      ui.abort "No organization ID specified and no default organization ID set."

    organization_id = default_organization_id

  fleet_root := compute_fleet_root parsed config ui
  with_artemis parsed config cache ui: | artemis/Artemis |
    Fleet.init fleet_root artemis --organization_id=organization_id --ui=ui

create_identities parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  output_directory := parsed["output-directory"]
  count := parsed["count"]
  group := parsed["group"]

  with_fleet parsed config cache ui: | fleet/Fleet |
    created_files := fleet.create_identities count
        --group=group
        --output_directory=output_directory
    ui.info "Created $created_files.size identity file(s)."

roll_out parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  diff_bases := parsed["diff-base"]

  with_fleet parsed config cache ui: | fleet/Fleet |
    fleet.roll_out --diff_bases=diff_bases

status parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  include_healthy := parsed["include-healthy"]
  include_never_seen := parsed["include-never-seen"]

  with_fleet parsed config cache ui: | fleet/Fleet |
    fleet.status --include_healthy=include_healthy --include_never_seen=include_never_seen

add_device parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device_id := parsed["device-id"]
  name := parsed["name"]
  aliases := parsed["alias"]
  group := parsed["group"]

  with_fleet parsed config cache ui: | fleet/Fleet |
    if not fleet.has_group group:
      ui.abort "Group '$group' not found."

    with_artemis parsed config cache ui: | artemis/Artemis |
      broker := artemis.connected_broker
      devices := broker.get_devices --device_ids=[device_id]
      if devices.is_empty:
        ui.abort "Device $device_id not found."

      device/DeviceDetailed := devices[device_id]
      if device.organization_id != fleet.organization_id:
        ui.abort "Device $device_id is not in the same organization as the fleet."

      fleet.add_device --device_id=device.id --group=group --name=name --aliases=aliases
      ui.info "Added device $device_id to fleet."

group_list parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := compute_fleet_root parsed config ui
  fleet_file := Fleet.load_fleet_file fleet_root --ui=ui
  ui.do --kind=Ui.RESULT: | printer/Printer |
    structured := []
    fleet_file.group_pods.do: | name pod_reference/PodReference |
      structured.add {
        "name": name,
        "pod": pod_reference.to_string,
      }
    printer.emit structured --header={"name": "Group", "pod": "Pod"}

group_create parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  pod := parsed["pod"]
  template := parsed["template"]
  name := parsed["name"]
  force := parsed["force"]

  with_fleet parsed config cache ui: | fleet/Fleet |
    pod_reference/PodReference? := null
    if pod:
      pod_reference = PodReference.parse pod --on_error=:
        ui.abort "Invalid pod reference: $pod"
    else if template:
      pod_reference = fleet.pod_reference_for_group template
    else:
      pod_reference = fleet.pod_reference_for_group DEFAULT_GROUP

    if not force:
      if not fleet.pod_exists pod_reference:
        ui.abort "Pod $pod_reference does not exist."

    fleet_file := Fleet.load_fleet_file fleet.fleet_root_ --ui=ui
    if fleet_file.group_pods.contains name:
      ui.abort "Group $name already exists."
    fleet_file.group_pods[name] = pod_reference
    fleet_file.write
    ui.info "Created group $name."

group_update parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  pod := parsed["pod"]
  tag := parsed["tag"]
  name := parsed["name"]
  groups := parsed["group"]
  force := parsed["force"]

  if not name and not pod and not tag:
    ui.abort "No new name, tag, or pod reference given."

  if name and groups.size > 1:
    ui.abort "Cannot rename more than one group."

  if pod and tag:
    ui.abort "Cannot set both pod and tag."

  executed_actions/List := []

  with_fleet parsed config cache ui: | fleet/Fleet |
    fleet_root := fleet.fleet_root_
    fleet_file := Fleet.load_fleet_file fleet_root --ui=ui

    pod_reference/PodReference? := null
    if pod:
      pod_reference = PodReference.parse pod --on_error=:
        ui.abort "Invalid pod reference: $pod"
    groups.do: | group/string |
      if not fleet_file.group_pods.contains group:
        ui.abort "Group '$group' does not exist."

      if name and fleet_file.group_pods.contains name:
        ui.abort "Group '$name' already exists."

      if tag:
        old_pod_reference/PodReference := fleet_file.group_pods[group]
        pod_reference = old_pod_reference.with --tag=tag

      if not force:
        if not fleet.pod_exists pod_reference:
          ui.abort "Pod $pod_reference does not exist."

      if pod_reference:
        fleet_file.group_pods[group] = pod_reference
        executed_actions.add "Updated group '$group' to pod '$pod_reference'."

      if name:
        old_reference := fleet_file.group_pods[group]
        fleet_file.group_pods.remove group
        fleet_file.group_pods[name] = old_reference
        devices_file := Fleet.load_devices_file fleet_root --ui=ui
        move_devices_
            --fleet_root=fleet_root
            --ids_to_move={}
            --groups_to_move={group}
            --to=name
            --ui=ui
        executed_actions.add "Renamed group '$group' to '$name'."
    fleet_file.write
    executed_actions.do: ui.info it

group_remove parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  group := parsed["group"]

  fleet_root := compute_fleet_root parsed config ui

  fleet_file := Fleet.load_fleet_file fleet_root --ui=ui
  if not fleet_file.group_pods.contains group:
    ui.info "Group '$group' does not exist."
    return

  device_file := Fleet.load_devices_file fleet_root --ui=ui
  used_groups := {}
  device_file.devices.do: | device/DeviceFleet |
    used_groups.add device.group

  if used_groups.contains group:
    ui.abort "Group '$group' is in use."

  fleet_file.group_pods.remove group
  fleet_file.write

  ui.info "Removed group $group."

group_move parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  to := parsed["to"]
  groups_to_move := parsed["group"]
  devices_to_move := parsed["device"]

  fleet_root := compute_fleet_root parsed config ui

  if groups_to_move.is_empty and devices_to_move.is_empty:
    ui.abort "No devices or groups given."

  ids_to_move := {}
  with_fleet parsed config cache ui: | fleet/Fleet |
    devices_to_move.do: | device |
      ids_to_move.add (fleet.resolve_alias device).id

  fleet_file := Fleet.load_fleet_file fleet_root --ui=ui
  if not fleet_file.group_pods.contains to:
    ui.abort "Group '$to' does not exist."

  groups_to_move_set := {}
  groups_to_move_set.add_all groups_to_move

  moved_count := move_devices_
      --fleet_root=fleet_root
      --ids_to_move=ids_to_move
      --groups_to_move=groups_to_move_set
      --to=to
      --ui=ui
  ui.info "Moved $moved_count devices to group '$to'."

move_devices_ -> int
    --fleet_root/string
    --ids_to_move/Set
    --groups_to_move/Set
    --to/string
    --ui/Ui:
  devices_file := Fleet.load_devices_file fleet_root --ui=ui
  new_devices := []

  moved_count := 0
  devices_file.devices.do: | fleet_device/DeviceFleet |
    if ids_to_move.contains fleet_device.id or groups_to_move.contains fleet_device.group:
      new_devices.add (fleet_device.with --group=to)
      moved_count++
    else:
      new_devices.add fleet_device

  if moved_count != 0:
    new_devices_file := DevicesFile devices_file.path new_devices
    new_devices_file.write

  return moved_count
