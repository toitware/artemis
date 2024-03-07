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
import ..pod-registry
import ..ui
import ..utils

create-fleet-commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "fleet"
      --help="""
        Manage multiple devices at the same time.

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

  init-cmd := cli.Command "init"
      --help="""
        Initialize a fleet root.

        This command initializes a fleet root in a directory, so it can be
        used by the other fleet commands.

        The directory can be specified using the '--fleet-root' option.

        The fleet will be in the given organization id. If no organization id
        is given, the default organization is used.
        """
      --options=[
        OptionUuid "organization-id"
            --help="The organization to use."
      ]
      --run=:: init it config cache ui
  cmd.add init-cmd

  create-identities-cmd := cli.Command "create-identities"
      --help="""
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
            --help="Directory to write the identity files to."
            --default=".",
        cli.Option "group"
            --default=DEFAULT-GROUP
            --help="Add the devices to a group.",
      ]
      --aliases=[
        "provision",
      ]
      --rest=[
        cli.OptionInt "count"
            --help="Number of identity files to create."
            --required,
      ]
      --run=:: create-identities it config cache ui
  cmd.add create-identities-cmd

  create-identity-cmd := cli.Command "create-identity"
      --help="""
        Create a single identity file.

        An identity file describe a device, containing their ID and organization.
        For each written identity file, a device is provisioned in the Toit
        cloud.

        Use 'flash-station flash' to flash a device with an identity file and a
        specification or firmware image.

        If no ID is given, a new random ID is generated.

        This command requires the broker to be configured.
        This command requires Internet access.
        """
      --options=[
        cli.Option "output-directory"
            --type="directory"
            --help="Directory to write the identity file to."
            --default=".",
        cli.Option "group"
            --default=DEFAULT-GROUP
            --help="Add the devices to a group.",
        cli.Option "name"
            --help="The name of the device.",
        cli.Option "alias"
            --help="The alias of the device."
            --multi
            --split-commas,
      ]
      --rest=[
        OptionUuid "id"
            --help="The ID of the device.",
      ]
      --run=:: create-identity it config cache ui
  cmd.add create-identity-cmd

  update-cmd := cli.Command "update"
      --help="Deprecated alias for 'roll-out'."
      --options=[
        cli.Option "diff-base"
            --type="pod-file"
            --help="The base pod to use for diff-based updates."
            --multi,
      ]
      --run=::
        ui.warning "The 'fleet update' command is deprecated. Use 'fleet roll-out' instead."
        roll-out it config cache ui
  cmd.add update-cmd

  roll-out-cmd := cli.Command "roll-out"
      --aliases=[
        "rollout",
        "deploy"
      ]
      --help="""
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
            --help="The base pod to use for diff-based updates."
            --multi,
      ]
      --run=:: roll-out it config cache ui
  cmd.add roll-out-cmd

  status-cmd := cli.Command "status"
      --help="""
        Show the status of the fleet.
        """
      --options=[
        cli.Flag "include-healthy"
            --help="Show healthy devices."
            --default=true,
        cli.Flag "include-never-seen"
            --help="Include devices that have never been seen."
            --default=false,
      ]
      --run=:: status it config cache ui
  cmd.add status-cmd

  add-device-cmd := cli.Command "add-device"
      --help="""
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
            --help="The name of the device.",
        cli.Option "alias"
            --help="The alias of the device."
            --multi
            --split-commas,
        cli.Option "group"
            --default=DEFAULT-GROUP
            --help="Add the device to a group.",
      ]
      --rest=[
        OptionUuid "device-id"
            --help="The ID of the device to add."
            --required,
      ]
      --run=:: add-device it config cache ui
  cmd.add add-device-cmd

  group-cmd := cli.Command "group"
      --help="""
        Manage groups in the fleet.

        Groups are used to organize devices in the fleet. Devices can be
        added to groups when they are created, or later using the 'group move'
        command.
        """
  cmd.add group-cmd

  group-list-cmd := cli.Command "list"
      --help="List the groups in the fleet."
      --run=:: group-list it config cache ui
  group-cmd.add group-list-cmd

  group-create-cmd := cli.Command "create"
      --help="""
        Create a group in the fleet.

        If a pod reference is given, uses it for the new group.
        If a template is given, uses its pod reference for the new group.
        If neither a pod reference nor a template is given uses the default pod reference.
        """
      --options=[
        cli.Option "pod"
            --help="The pod reference to use for the group.",
        cli.Option "template"
            --help="The existing group that should be used as a template for the new group.",
        cli.Flag "force"
            --help="Create the group even if the pod doesn't exist."
            --short-name="f",
      ]
      --rest=[
        cli.Option "name"
            --help="The name of the new group."
            --required,
      ]
      --run=:: group-create it config cache ui
  group-cmd.add group-create-cmd

  group-update-cmd := cli.Command "update"
      --help="""
        Update one or several groups in the fleet.

        Updates the pod reference and/or name of the given groups. However,
        when using the '--name' flag only one group can be given.

        The new pod can be specified by a qualified pod-reference or by providing
        a new tag for the existing pod.
        """
      --options=[
        cli.Option "pod"
            --type="pod-reference"
            --help="The pod reference to use for the group.",
        cli.Option "name"
            --help="The new name of the group.",
        cli.Option "tag"
            --help="The tag to update the existing pod to.",
        cli.Flag "force"
            --help="Update the group even if the pod doesn't exist."
            --short-name="f",
      ]
      --rest=[
        cli.Option "group"
            --help="The name of the group to update."
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
      --run=:: group-update it config cache ui
  group-cmd.add group-update-cmd

  group-remove-cmd := cli.Command "remove"
      --help="Remove a group from the fleet."
      --rest=[
        cli.Option "group"
            --help="The name of the group to remove."
            --required,
      ]
      --run=:: group-remove it config cache ui
  group-cmd.add group-remove-cmd

  group-move-cmd := cli.Command "move"
      --help="Move devices between groups."
      --options=[
        cli.Option "to"
            --help="The group to move the devices to."
            --required,
        cli.Option "group"
            --help="A group to move the devices from."
            --multi,
      ]
      --rest=[
        cli.Option "device"
            --help="The ID, namer or alias of a device to move."
            --multi,
      ]
      --run=:: group-move it config cache ui
  group-cmd.add group-move-cmd

  return [cmd]

init parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet-root-flag := parsed["fleet-root"]
  organization-id := parsed["organization-id"]

  if not organization-id:
    default-organization-id := default-organization-from-config config
    if not default-organization-id:
      ui.abort "No organization ID specified and no default organization ID set."

    organization-id = default-organization-id

  fleet-root := compute-fleet-root parsed config ui
  with-artemis parsed config cache ui: | artemis/Artemis |
    FleetWithDevices.init fleet-root artemis --organization-id=organization-id --ui=ui

create-identities parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  output-directory := parsed["output-directory"]
  count := parsed["count"]
  group := parsed["group"]

  if count < 0:
    ui.abort "Count can't be negative."

  written-count := 0
  try:
    with-devices-fleet parsed config cache ui: | fleet/FleetWithDevices |
      count.repeat:
        fleet.create-identity
            --group=group
            --output-directory=output-directory
        written-count++
  finally:
    if count == written-count or written-count > 0:
      ui.info "Created $written-count identity file(s)."

create-identity parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  output-directory := parsed["output-directory"]
  group := parsed["group"]
  name := parsed["name"]
  aliases := parsed["alias"]
  id := parsed["id"]

  with-devices-fleet parsed config cache ui: | fleet/FleetWithDevices |
    path := fleet.create-identity
        --id=id
        --name=name
        --aliases=aliases
        --group=group
        --output-directory=output-directory
    ui.info "Created identity file $path."


roll-out parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  diff-bases := parsed["diff-base"]

  with-devices-fleet parsed config cache ui: | fleet/FleetWithDevices |
    fleet.roll-out --diff-bases=diff-bases

status parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  include-healthy := parsed["include-healthy"]
  include-never-seen := parsed["include-never-seen"]

  with-devices-fleet parsed config cache ui: | fleet/FleetWithDevices |
    fleet.status --include-healthy=include-healthy --include-never-seen=include-never-seen

add-device parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device-id := parsed["device-id"]
  name := parsed["name"]
  aliases := parsed["alias"]
  group := parsed["group"]

  with-devices-fleet parsed config cache ui: | fleet/FleetWithDevices |
    if not fleet.has-group group:
      ui.abort "Group '$group' not found."

    with-artemis parsed config cache ui: | artemis/Artemis |
      broker := artemis.connected-broker
      devices := broker.get-devices --device-ids=[device-id]
      if devices.is-empty:
        ui.abort "Device $device-id not found."

      device/DeviceDetailed := devices[device-id]
      if device.organization-id != fleet.organization-id:
        ui.abort "Device $device-id is not in the same organization as the fleet."

      fleet.add-device --device-id=device.id --group=group --name=name --aliases=aliases
      ui.info "Added device $device-id to fleet."

group-list parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet-root := compute-fleet-root parsed config ui
  fleet-file := Fleet.load-fleet-file fleet-root --ui=ui
  ui.do --kind=Ui.RESULT: | printer/Printer |
    structured := []
    fleet-file.group-pods.do: | name pod-reference/PodReference |
      structured.add {
        "name": name,
        "pod": pod-reference.to-string,
      }
    printer.emit structured --header={"name": "Group", "pod": "Pod"}

group-create parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  pod := parsed["pod"]
  template := parsed["template"]
  name := parsed["name"]
  force := parsed["force"]

  with-devices-fleet parsed config cache ui: | fleet/FleetWithDevices |
    pod-reference/PodReference? := null
    if pod:
      pod-reference = PodReference.parse pod --on-error=:
        ui.abort "Invalid pod reference: $pod"
    else if template:
      pod-reference = fleet.pod-reference-for-group template
    else:
      pod-reference = fleet.pod-reference-for-group DEFAULT-GROUP

    if not force:
      if not fleet.pod-exists pod-reference:
        ui.abort "Pod $pod-reference does not exist."

    fleet-file := Fleet.load-fleet-file fleet.fleet-root_ --ui=ui
    if fleet-file.group-pods.contains name:
      ui.abort "Group $name already exists."
    fleet-file.group-pods[name] = pod-reference
    fleet-file.write
    ui.info "Created group $name."

group-update parsed/cli.Parsed config/Config cache/Cache ui/Ui:
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

  executed-actions/List := []

  with-devices-fleet parsed config cache ui: | fleet/FleetWithDevices |
    fleet-root := fleet.fleet-root_
    fleet-file := Fleet.load-fleet-file fleet-root --ui=ui

    pod-reference/PodReference? := null
    if pod:
      pod-reference = PodReference.parse pod --on-error=:
        ui.abort "Invalid pod reference: $pod"
    groups.do: | group/string |
      if not fleet-file.group-pods.contains group:
        ui.abort "Group '$group' does not exist."

      if name and fleet-file.group-pods.contains name:
        ui.abort "Group '$name' already exists."

      if tag:
        old-pod-reference/PodReference := fleet-file.group-pods[group]
        pod-reference = old-pod-reference.with --tag=tag

      if not force:
        if not fleet.pod-exists pod-reference:
          ui.abort "Pod $pod-reference does not exist."

      if pod-reference:
        fleet-file.group-pods[group] = pod-reference
        executed-actions.add "Updated group '$group' to pod '$pod-reference'."

      if name:
        old-reference := fleet-file.group-pods[group]
        fleet-file.group-pods.remove group
        fleet-file.group-pods[name] = old-reference
        devices-file := FleetWithDevices.load-devices-file fleet-root --ui=ui
        move-devices_
            --fleet-root=fleet-root
            --ids-to-move={}
            --groups-to-move={group}
            --to=name
            --ui=ui
        executed-actions.add "Renamed group '$group' to '$name'."
    fleet-file.write
    executed-actions.do: ui.info it

group-remove parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  group := parsed["group"]

  fleet-root := compute-fleet-root parsed config ui

  fleet-file := Fleet.load-fleet-file fleet-root --ui=ui
  if not fleet-file.group-pods.contains group:
    ui.info "Group '$group' does not exist."
    return

  device-file := FleetWithDevices.load-devices-file fleet-root --ui=ui
  used-groups := {}
  device-file.devices.do: | device/DeviceFleet |
    used-groups.add device.group

  if used-groups.contains group:
    ui.abort "Group '$group' is in use."

  fleet-file.group-pods.remove group
  fleet-file.write

  ui.info "Removed group $group."

group-move parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  to := parsed["to"]
  groups-to-move := parsed["group"]
  devices-to-move := parsed["device"]

  fleet-root := compute-fleet-root parsed config ui

  if groups-to-move.is-empty and devices-to-move.is-empty:
    ui.abort "No devices or groups given."

  ids-to-move := {}
  with-devices-fleet parsed config cache ui: | fleet/FleetWithDevices |
    devices-to-move.do: | device |
      ids-to-move.add (fleet.resolve-alias device).id

  fleet-file := Fleet.load-fleet-file fleet-root --ui=ui
  if not fleet-file.group-pods.contains to:
    ui.abort "Group '$to' does not exist."

  groups-to-move-set := {}
  groups-to-move-set.add-all groups-to-move

  moved-count := move-devices_
      --fleet-root=fleet-root
      --ids-to-move=ids-to-move
      --groups-to-move=groups-to-move-set
      --to=to
      --ui=ui
  ui.info "Moved $moved-count devices to group '$to'."

move-devices_ -> int
    --fleet-root/string
    --ids-to-move/Set
    --groups-to-move/Set
    --to/string
    --ui/Ui:
  devices-file := FleetWithDevices.load-devices-file fleet-root --ui=ui
  new-devices := []

  moved-count := 0
  devices-file.devices.do: | fleet-device/DeviceFleet |
    if ids-to-move.contains fleet-device.id or groups-to-move.contains fleet-device.group:
      new-devices.add (fleet-device.with --group=to)
      moved-count++
    else:
      new-devices.add fleet-device

  if moved-count != 0:
    new-devices-file := DevicesFile devices-file.path new-devices
    new-devices-file.write

  return moved-count
