// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show *
import fs
import host.file
import uuid

import .device show
    extract-device
    build-extract-format-options
    EXTRACT-FORMATS-COMMAND-HELP

import .auth as auth-cmd
import .serial show PARTITION-OPTION
import .utils_
import ..artemis
import ..brokers.broker show BrokerCli
import ..config
import ..cache
import ..device
import ..firmware
import ..fleet
import ..pod
import ..pod-registry
import ..server-config show get-server-from-config
import ..utils

create-fleet-commands -> List:
  cmd := Command "fleet"
      --help="""
        Manage multiple devices at the same time.

        The 'fleet' command allows you to manage multiple devices at the same
        time. It can be used to create identity files and update multiple
        devices at the same time.

        The 'fleet roll-out' command can be used intuitively to send update
        requests to multiple devices.

        The remaining commands are designed to be used in a workflow, where
        multiple devices are flashed with the same pod. Frequently, flash stations
        are not connected to the Internet, so the 'fleet add-devices' and
        'pod build' commands are used to create the necessary files, which are
        then transferred to the flash station.

        A typical flashing workflow consists of:
        1. Create an Artemis pod using 'pod build'.
        2. Create identity files using 'fleet add-devices'.
        3. Transfer the pod and the identity files to the flash station.
        4. Flash the devices using 'serial flash'.
        """

  init-cmd := Command "init"
      --help="""
        Initialize a fleet root.

        This command initializes a fleet root in a directory, so it can be
        used by the other fleet commands.

        The directory can be specified using the '--fleet-root' option.

        The fleet will be in the given organization id. If no organization id
        is given, the default organization is used.

        If a broker is given, it must match the name of one that has been added using
        the 'config broker add' command. If no broker is given, the default broker is used.
        """
      --options=[
        OptionUuid "organization-id"
            --help="The organization to use.",
        Option "broker"
            --help="The broker to use.",
      ]
      --examples=[
        Example "Initialize a fleet root in the current directory with the default organization:"
            --arguments=""
            --global-priority=8,
        Example "Initialize a fleet in directory 'fleet' with organization '12345678-1234-1234-1234-123456789abc':"
            --arguments="--fleet-root=./fleet --organization-id=12345678-1234-1234-1234-123456789abc"
      ]
      --run=:: init it
  cmd.add init-cmd

  login-cmd := Command "login"
      --aliases=["signin", "sign-in", "log-in"]
      --help="""
        Log in to the fleet's broker.

        This is a convenience command that extracts the broker server from the
        fleet configuration.
        """
      --options=auth-cmd.SIGNIN-OPTIONS
      --run=:: login it
  cmd.add login-cmd

  add-devices-cmd := Command "add-devices"
      --aliases=["create-identities", "provision"]
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
        Option "output-directory"
            --type="directory"
            --help="Directory to write the identity files to."
            --default=".",
        Option "group"
            --default=DEFAULT-GROUP
            --help="Add the devices to a group.",
      ]
      --rest=[
        OptionInt "count"
            --help="Number of identity files to create."
            --required,
      ]
      --examples=[
        Example "Create 10 identity files in the current directory:"
            --arguments="10",
        Example "Create 10 identity files in the directory 'identities' and add them to group 'g1':"
            --arguments="--output-directory=identities --group=g1 10",
      ]
      --run=:: add-devices it
  cmd.add add-devices-cmd

  add-device-cmd := Command "add-device"
      --aliases=["create-device"]
      --help="""
        Add a new device to the fleet.

        If no output file is given, the device is just added to the fleet. In that
        case you can use the 'device extract' command to extract an image, or you can
        use 'serial flash' to flash it.

        $EXTRACT-FORMATS-COMMAND-HELP

        If no id is given, a new random ID is generated.
        if no name is given, a random name is generated.

        This command requires the broker to be configured.
        This command requires Internet access.
        """
      --options=(build-extract-format-options --no-required) + [
        Option "output"
            --short-name="o"
            --type="file"
            --help="The file to write the output to.",
        Option "name"
            --help="The name of the device.",
        Option "alias"
            --help="The alias of the device."
            --multi
            --split-commas,
        Option "group"
            --default=DEFAULT-GROUP
            --help="The group of the new device.",
        OptionUuid "id"
            --help="The id of the device.",
        Flag "default"
            --default=true
            --help="Make this device the default device.",
      ]
      --examples=[
        Example "Add a new device in group 'roof-solar':"
            --arguments="--group=roof-solar",
        Example "Add a new device and write the identity file to 'device.identity':"
            --arguments="--format=identity -o device.identity",
        Example "Create a tar file 'device.tar' for a new host device 'berry' in group 'host-devices':"
            --arguments="--name=berry --group=host-devices --format=tar -o device.tar",
      ]
      --run=:: add-device it
  cmd.add add-device-cmd

  roll-out-cmd := Command "roll-out"
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
        Option "diff-base"
            --type="pod-file|reference"
            --help="The base pod file or reference to use for diff-based updates."
            --multi,
      ]
      --examples=[
        Example "Roll out the fleet configuration to all devices:"
            --arguments=""
            --global-priority=2,
        Example """
            Roll out the fleet configuration to all devices using pods base1.pod
            and base2.pod as diff bases:"""
            --arguments="--diff-base=base1.pod --diff-base=base2.pod",
        Example """
            Roll out the fleet configuration to all devices using pod 'my-pod@v2.1.0'
            as diff base:"""
            --arguments="--diff-base=my-pod@v2.1.0",
      ]
      --run=:: roll-out it
  cmd.add roll-out-cmd

  status-cmd := Command "status"
      --help="""
        Show the status of the fleet.
        """
      --options=[
        Flag "include-healthy"
            --help="Show healthy devices."
            --default=true,
        Flag "include-never-seen"
            --help="Include devices that have never been seen."
            --default=false,
      ]
      --examples=[
        Example "Show the status of the fleet:"
            --arguments=""
            --global-priority=5,
        Example "Show the status of the fleet, without healthy devices:"
            --arguments="--no-include-healthy",
        Example "Show the status of the fleet, including devices that have never been seen:"
            --arguments="--include-never-seen",
      ]
      --run=:: status it
  cmd.add status-cmd

  add-existing-device-cmd := Command "add-existing-device"
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
        Option "name"
            --help="The name of the device.",
        Option "alias"
            --help="The alias of the device."
            --multi
            --split-commas,
        Option "group"
            --default=DEFAULT-GROUP
            --help="Add the device to a group.",
      ]
      --rest=[
        OptionUuid "device-id"
            --help="The ID of the device to add."
            --required,
      ]
      --examples=[
        Example """
            Add device '12345678-1234-1234-1234-123456789abc' to group 'insect' with
            name 'wasp':"""
            --arguments="--name=wasp --group=insect 12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: add-existing-device it
  cmd.add add-existing-device-cmd

  group-cmd := Command "group"
      --help="""
        Manage groups in the fleet.

        Groups are used to organize devices in the fleet. Devices can be
        added to groups when they are created, or later using the 'group move'
        command.
        """
  cmd.add group-cmd

  group-list-cmd := Command "list"
      --aliases=["ls"]
      --help="List the groups in the fleet."
      --run=:: group-list it
  group-cmd.add group-list-cmd

  group-add-cmd := Command "add"
      --aliases=["create"]
      --help="""
        Add a group in the fleet.

        If a pod reference is given, uses it for the new group.
        If a template is given, uses its pod reference for the new group.
        If neither a pod reference nor a template is given uses the default pod reference.
        """
      --options=[
        Option "pod"
            --help="The pod reference to use for the group.",
        Option "template"
            --help="The existing group that should be used as a template for the new group.",
        Flag "force"
            --help="Create the group even if the pod doesn't exist."
            --short-name="f",
      ]
      --rest=[
        Option "name"
            --help="The name of the new group."
            --required,
      ]
      --examples=[
        Example "Create a group 'on-battery' using the pod 'battery-pod#11':"
            --arguments="--pod=battery-pod#11 on-battery",
        Example """
            Create a group 'on-battery-inaccessible' using the current pod of
            group 'on-battery':"""
            --arguments="--template=on-battery on-battery-inaccessible",
      ]
      --run=:: group-add it
  group-cmd.add group-add-cmd

  group-update-cmd := Command "update"
      --help="""
        Update one or several groups in the fleet.

        Updates the pod reference and/or name of the given groups. However,
        when using the '--name' flag only one group can be given.

        The new pod can be specified by a qualified pod-reference or by providing
        a new tag for the existing pod.
        """
      --options=[
        Option "pod"
            --type="pod-reference"
            --help="The pod reference to use for the group.",
        Option "name"
            --help="The new name of the group.",
        Option "tag"
            --help="The tag to update the existing pod to.",
        Flag "force"
            --help="Update the group even if the pod doesn't exist."
            --short-name="f",
      ]
      --rest=[
        Option "group"
            --help="The name of the group to update."
            --required
            --multi,
      ]
      --examples=[
        Example "Update groups 'on-battery' and 'wired' to use pods with tag 'v1.2':"
            --arguments="--tag=v1.2 on-battery wired",
        Example "Rename group 'g1' to 'g2'."
            --arguments="--name=g2 g1",
        Example "Update group 'default' to use pod 'my-podv1.0.0':"
            --arguments="--pod=my-pod@v1.0.0 default"
            --global-priority=3,
        Example "Update group 'g2' to use revision 11 of pod 'my-pod':"
            --arguments="--pod=my-pod#11 g2",
      ]
      --run=:: group-update it
  group-cmd.add group-update-cmd

  group-remove-cmd := Command "remove"
      --help="""
      Remove a group from the fleet.

      The group must be unused.
      """
      --rest=[
        Option "group"
            --help="The name of the group to remove."
            --required,
      ]
      --examples=[
        Example "Remove group 'g1':"
            --arguments="g1",
      ]
      --run=:: group-remove it
  group-cmd.add group-remove-cmd

  group-move-cmd := Command "move"
      --help="Move devices between groups."
      --options=[
        Option "to"
            --help="The group to move the devices to."
            --required,
        Option "group"
            --help="A group to move the devices from."
            --multi,
      ]
      --rest=[
        Option "device"
            --help="The ID, namer or alias of a device to move."
            --multi,
      ]
      --examples=[
        Example "Move all devices from group 'g1' to group 'g2':"
            --arguments="--to=g2 --group=g1",
        Example "Move devices 'big-whale' and 12345678-1234-1234-1234-123456789abc to group 'g2':"
            --arguments="--to=g2 big-whale 12345678-1234-1234-1234-123456789abc",
      ]
      --run=:: group-move it
  group-cmd.add group-move-cmd

  create-reference-cmd := Command "create-reference"
      --aliases=["create-ref"]
      --help="""
        Creates a reference file for this fleet.

        References can be used for pod-management commands, such as 'pod upload',
        but cannot be used for device management commands, such as 'fleet roll-out'.
        """
      --options=[
        Option "output"
            --short-name="o"
            --type="file"
            --help="The file to write the reference to."
            --required,
      ]
      --examples=[
        Example "Create a reference file 'my-fleet.ref':"
            --arguments="--output=my-fleet.ref",
      ]
      --run=:: create-reference it
  cmd.add create-reference-cmd

  migration-cmd := Command "migration"
      --aliases=["migrate"]
      --help="""
        Migrate a fleet to a new broker.

        - Add a new broker to your configuration. Use 'config broker add ...'.
        - Start the migration with 'migration start --broker=<broker>'.
        - Upload a new pod, and roll it out to the fleet with 'fleet roll-out'.
        - Check the status of the migration with the fleet's 'status' command.
        - Finish the migration with 'migration stop', once all devices have migrated.

        It is safe to roll out new pods to the fleet while a migration is in progress. As
        long as the migration is not finished, new pods will be rolled out to all brokers.
        """
  cmd.add migration-cmd

  migration-start-cmd := Command "start"
      --help="""
        Start the migration to a new broker.

        Use the fleet's 'status' to check the status of the migration.
        Use 'stop' to stop the migration.

        It is legal to start a migration even if one is already in progress.
        """
      --options=[
        Option "broker"
            --help="The broker to migrate to."
            --required,
      ]
      --examples=[
        Example "Migrate the fleet to the broker 'my-broker':"
            --arguments="--broker=my-broker",
      ]
      --run=:: migration-start it
  migration-cmd.add migration-start-cmd

  migration-stop-cmd := Command "stop"
      --help="""
          Stops the migration.

          Removes the old broker(s) from the fleet. From that point on,
          devices that still contact the old broker(s) will not be updated.

          If no broker is given, all old brokers are removed.
          Otherwise, only the given brokers are removed.

          Unless a migration was started while another one was still in progress,
          there should be only one old broker in the fleet.

          Without the '--force' flag, the command will abort if devices have not
          yet migrated to the new broker. If there are devices that have never
          been seen, then the command will *not* abort; even without this flag.
          """
      --options=[
        Flag "force"
            --short-name="f"
            --help="Remove the old broker(s) even if devices are still using them."
            --default=false,
        Option "broker"
            --help="The broker to remove."
            --multi,
      ]
      --examples=[
        Example "Finish the migration:"
            --arguments="",
        Example """
            Stop the migration for brokers 'old-broker1', 'old-broker2'.
            These will not be updated anymore:
            """
            --arguments="--broker=my-broker1 --broker=my-broker2",
      ]
      --run=:: migration-stop it
  migration-cmd.add migration-stop-cmd

  recovery-path := recovery-file-name --fleet-string="<FLEET-ID>"
  recovery-cmd := Command "recovery"
      --help="""
        Manage recovery URLs for the fleet.

        This command is deprecated. Use entries in the pod-specification instead.

        Recovery servers are used when a broker is unreachable and can't
        be restored. For example, if a domain name is lost.

        When devices are unable to reach their configured broker they periodically
        contact their recovery URLs to receive updated broker information.

        For example, say a device is configured to use
        'https://hxtyuwtaqffnqagvoxok.supabase.co', but that server is accidentally
        deleted. Since that address is not valid anymore, the devices will start
        to contact the recovery servers for updated broker information.

        Recovery servers can be set up on demand. In fact, it is recommended to
        point recovery addresses to servers that refuse connections, so that
        the devices don't establish TLS connections when they are not needed.
        If the main broker is lost, the recovery server can be updated to
        accept connections and return the new broker information.

        Recovery servers must be reachable with one of the common
        root certificates of the certificate_roots package.
        """
  cmd.add recovery-cmd

  recovery-add-cmd := Command "add"
      --help="""
          Add a recovery URL to this fleet.
          """
      --rest=[
        Option "url"
            --help="The URL of the recovery server."
            --required,
      ]
      --examples=[
        Example "Add a recovery URL 'https://recovery.toit.io/recover.json':"
            --arguments="https://recovery.toit.io/recover.json",
      ]
      --run=:: recovery-add it
  recovery-cmd.add recovery-add-cmd

  recovery-remove-cmd := Command "remove"
      --help="""
          Remove a recovery URL from this fleet.
          """
      --options=[
        Flag "all"
            --help="Remove all recovery servers.",
        Flag "force"
            --short-name="f"
            --help="Don't error if the recovery server doesn't exist.",
      ]
      --rest=[
        Option "url"
            --help="The URL of the recovery server."
            --multi,
      ]
      --examples=[
        Example "Remove the recovery URL 'https://recovery.toit.io/recover.json':"
            --arguments="https://recovery.toit.io/recover.json",
      ]
      --run=:: recovery-remove it
  recovery-cmd.add recovery-remove-cmd

  recovery-list-cmd := Command "list"
      --aliases=["ls"]
      --help="""
          List the recovery URLs for this fleet.
          """
      --run=:: recovery-list it
  recovery-cmd.add recovery-list-cmd

  recovery-export-cmd := Command "export"
      --help="""
          Export the current broker of this fleet as recovery information.

          The written JSON file should be served on the recovery server(s).
          """
      --options=[
        Option "output"
            --short-name="o"
            --help="The file to write the recovery information to."
            --required,
      ]
      --examples=[
        Example "Export the current broker to 'recovery.json':"
            --arguments="-o recovery.json",
      ]
      --run=:: recovery-export it
  recovery-cmd.add recovery-export-cmd

  return [cmd]

init invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  fleet-root-flag := invocation["fleet-root"]
  organization-id := invocation["organization-id"]
  broker-name := invocation["broker"]

  if not organization-id:
    default-organization-id := default-organization-from-config --cli=cli
    if not default-organization-id:
      ui.abort "No organization ID specified and no default organization ID set."

    organization-id = default-organization-id

  broker-config := ?
  if broker-name:
    broker-config = get-server-from-config --name=broker-name --cli=cli
  else:
    broker-config = get-server-from-config --key=CONFIG-BROKER-DEFAULT-KEY --cli=cli

  default-recovery-urls := (cli.config.get CONFIG-RECOVERY-SERVERS-KEY) or []

  fleet-root := compute-fleet-root-or-ref invocation
  with-artemis invocation: | artemis/Artemis |
    fleet-file := FleetWithDevices.init fleet-root artemis
        --organization-id=organization-id
        --broker-config=broker-config
        --recovery-url-prefixes=default-recovery-urls
        --cli=cli

    fleet-file.recovery-urls.do: | url/string |
      ui.info "Added recovery URL: $url"
    ui.info "Fleet root '$fleet-root' initialized."
    ui.emit --kind=Ui.RESULT
        --structured=: {
          "id": "$fleet-file.id",
          "broker": fleet-file.broker-config.to-json --base64 --der-serializer=: unreachable,
          "recovery-urls": fleet-file.recovery-urls,
        }
        --text=:
          // Don't print anything.
          null

login invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  with-pod-fleet invocation: | fleet/Fleet |
    broker := fleet.broker
    broker-name := broker.server-config.name
    ui.info "Logging in to broker '$broker-name'."
    broker-authenticatable := BrokerCli broker.server-config --cli=cli
    auth-cmd.sign-in invocation --name=broker-name --authenticatable=broker-authenticatable

add-devices invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  output-directory := invocation["output-directory"]
  count := invocation["count"]
  group := invocation["group"]

  if count < 0:
    ui.abort "Count can't be negative."

  written-ids := {:}
  try:
    with-devices-fleet invocation: | fleet/FleetWithDevices |
      count.repeat:
        id := random-uuid
        path := fleet.create-identity
            --id=id
            --group=group
            --output-directory=output-directory
        written-ids["$id"] = path
  finally:
    ui.emit --kind=Ui.RESULT
        --structured=: written-ids
        --text=:
          // Unless we didn't manage to create any identity (and more than 0 was requested),
          // report the number of created identity files.
          written-ids.size > 0 or count == 0
            ? "Created $written-ids.size identity file(s)."
            : null

add-device invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui
  params := invocation.parameters

  output := params["output"]
  format := params["format"]
  name := params["name"]
  aliases := params["alias"]
  group := params["group"]
  id := params["id"]
  partitions := params["partition"]
  should-make-default := params["default"]

  // If no id is given, just create one randomly.
  id = id or random-uuid

  if output and not format:
    ui.abort "Output file given without format."

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    with-tmp-directory: | tmp-dir |
      identity-path := fleet.create-identity
          --id=id
          --name=name
          --aliases=aliases
          --group=group
          --output-directory=tmp-dir

      fleet-device := fleet.device id
      if output:
        extract-device fleet-device
            --fleet=fleet
            --format=format
            --partitions=partitions
            --output=output
            --cli=cli

      if should-make-default: make-default_ --device-id=id --cli=cli
      ui.emit --kind=Ui.RESULT
          --structured=: {
            "name": fleet-device.name,
            "id": "$fleet-device.id",
            "group": fleet-device.group,
            "fleet-id": "$fleet.id",
          }
          --text=:
            "Successfully added device $fleet-device.name ($id) in group $fleet-device.group."

roll-out invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  diff-bases := invocation["diff-base"]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    pod-diff-bases := diff-bases.map: | file-or-ref/string |
      if file.is-file file-or-ref:
        Pod.parse file-or-ref --tmp-directory=fleet.artemis.tmp-directory --cli=cli
      else:
        fleet.download (PodReference.parse file-or-ref --cli=cli)
    fleet.roll-out --diff-bases=pod-diff-bases

status invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  include-healthy := invocation["include-healthy"]
  include-never-seen := invocation["include-never-seen"]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    fleet.status --include-healthy=include-healthy --include-never-seen=include-never-seen

add-existing-device invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  device-id := invocation["device-id"]
  name := invocation["name"]
  aliases := invocation["alias"]
  group := invocation["group"]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    if not fleet.has-group group:
      ui.abort "Group '$group' not found."

    broker := fleet.broker
    devices := broker.get-devices --device-ids=[device-id]
    if devices.is-empty:
      ui.abort "Device $device-id not found."

    device/DeviceDetailed := devices[device-id]
    if device.organization-id != fleet.organization-id:
      ui.abort "Device $device-id is not in the same organization as the fleet."

    fleet.add-device --device-id=device.id --group=group --name=name --aliases=aliases
    ui.info "Added device $device-id to fleet."

group-list invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    fleet-file := fleet.fleet-file_

    structured := []
    fleet-file.group-pods.do: | name pod-reference/PodReference |
      structured.add {
        "name": name,
        "pod": pod-reference.to-string,
      }
    ui.emit-table
      --kind=Ui.RESULT
      --header={"name": "Group", "pod": "Pod"}
      structured

group-add invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  pod := invocation["pod"]
  template := invocation["template"]
  name := invocation["name"]
  force := invocation["force"]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
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
        ui.abort "Pod '$pod-reference' does not exist."

    fleet-file := fleet.fleet-file_
    if fleet-file.group-pods.contains name:
      ui.abort "Group '$name' already exists."
    fleet-file.group-pods[name] = pod-reference
    fleet-file.write
    ui.info "Added group '$name'."

group-update invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui
  params := invocation.parameters

  pod := params["pod"]
  tag := params["tag"]
  name := params["name"]
  groups := params["group"]
  force := params["force"]

  if not name and not pod and not tag:
    ui.abort "No new name, tag, or pod reference given."

  if name and groups.size > 1:
    ui.abort "Cannot rename more than one group."

  if pod and tag:
    ui.abort "Cannot set both pod and tag."

  executed-actions/List := []

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    fleet-root := fleet.root
    fleet-file := fleet.fleet-file_

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
          ui.abort "Pod '$pod-reference' does not exist."

      if pod-reference:
        fleet-file.group-pods[group] = pod-reference
        executed-actions.add "Updated group '$group' to pod '$pod-reference'."

      if name:
        old-reference := fleet-file.group-pods[group]
        fleet-file.group-pods.remove group
        fleet-file.group-pods[name] = old-reference
        devices-file := FleetWithDevices.load-devices-file fleet-root --cli=cli
        move-devices_
            --fleet-root=fleet-root
            --ids-to-move={}
            --groups-to-move={group}
            --to=name
            --cli=cli
        executed-actions.add "Renamed group '$group' to '$name'."
    fleet-file.write
    executed-actions.do: ui.info it

group-remove invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  group := invocation["group"]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    fleet-file := fleet.fleet-file_
    if not fleet-file.group-pods.contains group:
      ui.info "Group '$group' does not exist."
      return

    device-file := FleetWithDevices.load-devices-file fleet.root --cli=cli
    used-groups := {}
    device-file.devices.do: | device/DeviceFleet |
      used-groups.add device.group

    if used-groups.contains group:
      ui.abort "Group '$group' is in use."

    fleet-file.group-pods.remove group
    fleet-file.write

    ui.info "Removed group '$group'."

group-move invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  to := invocation["to"]
  groups-to-move := invocation["group"]
  devices-to-move := invocation["device"]

  ids-to-move := {}
  with-devices-fleet invocation: | fleet/FleetWithDevices |
    devices-to-move.do: | device |
      ids-to-move.add (fleet.resolve-alias device).id

    fleet-root := fleet.root

    if groups-to-move.is-empty and devices-to-move.is-empty:
      ui.abort "No devices or groups given."

    fleet-file := fleet.fleet-file_
    if not fleet-file.group-pods.contains to:
      ui.abort "Group '$to' does not exist."

    groups-to-move-set := {}
    groups-to-move-set.add-all groups-to-move

    moved-count := move-devices_
        --fleet-root=fleet-root
        --ids-to-move=ids-to-move
        --groups-to-move=groups-to-move-set
        --to=to
        --cli=cli
    ui.info "Moved $moved-count devices to group '$to'."

move-devices_ -> int
    --fleet-root/string
    --ids-to-move/Set
    --groups-to-move/Set
    --to/string
    --cli/Cli:
  devices-file := FleetWithDevices.load-devices-file fleet-root --cli=cli
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

create-reference invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  output := invocation["output"]

  with-pod-fleet invocation: | fleet/Fleet |
    fleet.write-reference --path=output
    ui.info "Created reference file '$output'."

migration-start invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  broker-name := invocation["broker"]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    new-broker := get-server-from-config --name=broker-name --cli=cli
    fleet.migration-start --broker-config=new-broker
    ui.info "Started migration to broker '$broker-name'. Use 'fleet status' to monitor the migration."

migration-stop invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  force := invocation["force"]
  brokers := invocation["broker"]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    fleet.migration-stop brokers --force=force
    if brokers.is-empty:
      ui.info "Stopped all migration."
    else:
      quoted := brokers.map: "'$it'"
      joined := quoted.join ", "
      ui.info "Stopped migration for broker(s) $joined."

recovery-file-name --fleet-string/string -> string:
  return "recover-$(fleet-string).json"

recovery-file-name --fleet-id/uuid.Uuid -> string:
  return recovery-file-name --fleet-string="$fleet-id"

recovery-add invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  ui.warning "The 'recovery' command is deprecated. Use entries in the pod-specification instead."

  url := invocation["url"]

  if url.ends-with "/":
    url = url[..url.size - 1]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    fleet.recovery-url-add url

    ui.info "Added recovery URL '$url'."

recovery-remove invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  ui.warning "The 'recovery' command is deprecated. Use entries in the pod-specification instead."

  all := invocation["all"]
  force := invocation["force"]
  urls := invocation["url"]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    if all:
      fleet.recovery-urls-remove-all
      ui.info "Removed all recovery URLs."
    else:
      urls.do: | url |
        if not fleet.recovery-url-remove url:
          if not force:
            ui.abort "Recovery URL '$url' not found."
          else:
            ui.info "Recovery URL '$url' not found."

      quoted := urls.map: "'$it'"
      joined := quoted.join ", "
      ui.info "Removed recovery URL(s) $joined."

recovery-list invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  ui.warning "The 'recovery' command is deprecated. Use entries in the pod-specification instead."

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    recovery-urls := fleet.recovery-urls
    if ui.wants-structured --kind=Ui.RESULT:
      ui.emit --kind=Ui.RESULT
          --structured=: recovery-urls
          --text=: unreachable
    else:
      if recovery-urls.is-empty:
        ui.result "No recovery URLs configured."
      else:
        ui.emit-list
            --kind=Ui.RESULT
            --title="Recovery urls"
            recovery-urls

recovery-export invocation/Invocation:
  cli := invocation.cli
  ui := cli.ui

  output := invocation["output"]

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    recovery-info := fleet.recovery-info
    file.write-content --path=output recovery-info
    ui.info "Exported recovery information to '$output'."
