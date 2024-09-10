// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show *
import host.file
import uuid

import .utils_
import ..artemis
import ..broker
import ..cache
import ..config
import ..fleet
import ..pod
import ..pod-registry
import ..sdk
import ..utils
import ...service.run.simulate show run-host

PARTITION-OPTION ::= OptionPatterns "partition"
    ["file:<name>=<path>", "empty:<name>=<size>"]
    --help="Add a custom partition to the device."
    --split-commas
    --multi

create-serial-commands -> List:
  cmd := Command "serial"
      --help="Serial port commands."

  flash-options := [
    Option "port"
        --short-name="p"
        --required,
    Option "baud",
    PARTITION-OPTION,
  ]

  flash-cmd := Command "flash"
      --help="""
        Flash a device with the firmware.

        The pod to flash on the device is found through the '$DEFAULT-GROUP' group
        or the specified '--group' in the current fleet.

        Unless '--no-default' is used, automatically makes this device the
        new default device.
        """
      --options=flash-options + [
        Flag "default"
            --default=true
            --help="Make this device the default device.",
        Option "name"
            --help="The name of the device.",
        Option "group"
            --default=DEFAULT-GROUP
            --help="Add this device to a group.",
        Option "local"
            --type="file"
            --help="A local pod file to flash.",
        Flag "simulate"
            --hidden
            --default=false,
      ]
      --rest=[
        Option "remote"
            --help="A remote pod reference; a UUID, name@tag, or name#revision.",
      ]
      --examples=[
        Example """
            Flash the device on port /dev/ttyUSB0 with the pod for the default
            group and add the new identity to the devices file:"""
            --arguments="--port /dev/ttyUSB0"
            --global-priority=6,
        Example """
            Flash the device on port /dev/ttyUSB0 with the pod for the 'production'
            group and add the new identity to the devices file in that group:"""
            --arguments="--port /dev/ttyUSB0 --group production",
        Example """
            Flash the device on port /dev/ttyUSB0 with the pod for the 'production'
            group and add the new identity to the devices file in that group, but
            don't make it the default device:"""
            --arguments="--port /dev/ttyUSB0 --group production --no-default",
      ]
      --run=:: flash it
  cmd.add flash-cmd

  flash-station-cmd := Command "flash-station"
      --help="""
        Commands for a flash station.

        Flash stations are typically used to flash devices in a factory.
        They don't have Internet access and must work with prebuilt
        identities and firmware images.

        Flash station commands don't need any valid fleet root.
        """
  cmd.add flash-station-cmd

  flash-station-flash-cmd := Command "flash"
      --help="""
        Flash a device on a flash station.

        Does not require Internet access, but uses identity files that have
        been prebuilt using 'fleet add-devices'.

        The 'port' argument is used to select the serial port to use.
        """
      --options=flash-options + [
        Option "pod"
            --type="file"
            --help="The pod to flash."
            --required,
        Option "identity"
            --type="file"
            --short-name="i"
            --help="The identity file to use."
            --required,
      ]
      --examples=[
        Example """
            Flash the device on port /dev/ttyUSB0 with the pod 'my-pod.pod' and
            the identity '12345678-1234-1234-1234-123456789abc.identity':"""
            --arguments="--port /dev/ttyUSB0 --pod my-pod.pod --identity 12345678-1234-1234-1234-123456789abc.identity",
      ]
      --run=:: flash --station it
  flash-station-cmd.add flash-station-flash-cmd

  return [cmd]

build-partitions-table_ partition-list/List --cli/Cli -> List:
  ui := cli.ui

  result := []
  partition-list.do: | partition-entry |
    if partition-entry is not Map:
      ui.abort "Partition entry must be a map."
    partition := partition-entry as Map
    type := partition.contains "file" ? "file" : "empty"
    description/string := partition[type]
    delimiter-index := description.index-of "="
    if delimiter-index < 0:
      ui.abort "Partition of type '$type' is malformed: '$description'."
    name := description[..delimiter-index]
    if name.is-empty:
      ui.abort "Partition of type '$type' has no name."
    if name.size > 15:
      ui.abort "Partition of type '$type' has name with more than 15 characters."
    value := description[delimiter-index + 1 ..]
    if type == "file":
      if not file.is-file value:
        ui.error "Partition '$type:$name' refers to invalid file."
        ui.error "No such file: $value."
        ui.abort
    else:
      size := int.parse value --on-error=:
        ui.abort "Partition '$type:$name' has illegal size: '$it'."
      if size <= 0:
        ui.abort "Partition '$type:$name' has illegal size: $size."
    result.add "$type:$description"
  return result

flash invocation/Invocation:
  params := invocation.parameters
  cli := invocation.cli
  ui := cli.ui

  port := params["port"]
  baud := params["baud"]
  simulate := params["simulate"]
  should-make-default := params["default"]
  name := params["name"]
  group := params["group"]
  local := params["local"]
  remote := params["remote"]
  partitions := build-partitions-table_ params["partition"] --cli=cli

  if local and remote:
    ui.abort "Cannot specify both a local pod file and a remote pod reference."

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    artemis := fleet.artemis
    broker := fleet.broker

    with-tmp-directory: | tmp-dir/string |
      device-id := random-uuid
      identity-path := fleet.create-identity
          --id=device-id
          --name=name
          --group=group
          --output-directory=tmp-dir
      fleet-device := fleet.device device-id
      ui.inform "Successfully provisioned device $fleet-device.name ($device-id)."

      pod/Pod := ?
      reference/PodReference := ?
      if local:
        pod = Pod.from-file local
            --organization-id=fleet.organization-id
            --recovery-urls=fleet.recovery-urls
            --artemis=artemis
            --broker=broker
            --cli=cli
        reference = PodReference --id=pod.id
      else:
        if remote:
          reference = PodReference.parse remote --allow-name-only --cli=cli
        else:
          reference = fleet.pod-reference-for-group group
        pod = fleet.download reference

      // Make unique for the given device.
      config-bytes := pod.compute-device-specific-data
          --identity-path=identity-path
          --cli=cli

      config-path := "$tmp-dir/$(device-id).config"
      write-blob-to-file config-path config-bytes

      sdk := get-sdk pod.sdk-version --cli=cli
      if not simulate:
        ui.verbose:
          debug-line := "Flashing the device with pod $reference"
          if reference.id: debug-line += "."
          else: debug-line += " ($pod.id)."
          debug-line

        // Flash.
        sdk.flash
            --envelope-path=pod.envelope-path
            --config-path=config-path
            --port=port
            --baud-rate=baud
            --partitions=partitions
        if should-make-default: make-default_ --device-id=device-id --cli=cli
        info := "Successfully flashed device $fleet-device.name ($device-id"
        if group: info += " in group '$group'"
        info += ") with pod '$reference'"
        if reference.id: info += "."
        else: info += " ($pod.id)."
        ui.inform info
      else:
        ui.inform "Simulating flash."
        ui.inform "Using the local Artemis service and not the one specified in the specification."
        old-default := cli.config.get CONFIG-ARTEMIS-DEFAULT-KEY
        if should-make-default: make-default_ --device-id=device-id --cli=cli
        run-host
            --pod=pod
            --identity-path=identity-path
            --cli=cli

      if ui.wants-structured --kind=Ui.RESULT:
        ui.result {
              "device_id": "$device-id",
              "pod_id": "$pod.id",
              "pod_name": "$pod.name",
              "group": "$group",
            }

flash --station/bool invocation/Invocation:
  if not station: throw "INVALID_ARGUMENT"

  params := invocation.parameters
  cli := invocation.cli

  identity-path := params["identity"]
  pod-path := params["pod"]
  port := params["port"]
  baud := params["baud"]
  partitions := build-partitions-table_ params["partition"] --cli=cli

  with-artemis invocation: | artemis/Artemis |
    pod := Pod.parse pod-path --tmp-directory=artemis.tmp-directory --cli=cli
    with-tmp-directory: | tmp-dir/string |
      // Make unique for the given device.
      config-bytes := pod.compute-device-specific-data
          --identity-path=identity-path
          --cli=cli

      config-path := "$tmp-dir/config"
      write-blob-to-file config-path config-bytes

      // Flash.
      sdk := get-sdk pod.sdk-version --cli=cli
      sdk.flash
          --envelope-path=pod.envelope-path
          --config-path=config-path
          --port=port
          --baud-rate=baud
          --partitions=partitions
      identity := read-base64-ubjson identity-path
      // TODO(florian): Abstract away the identity format.
      device-id := uuid.parse identity["artemis.device"]["device_id"]
      cli.ui.inform "Successfully flashed device $device-id with pod '$pod.name' ($pod.id)."
