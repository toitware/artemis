// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import host.file
import uuid

import .utils_
import ..artemis
import ..cache
import ..config
import ..fleet
import ..pod
import ..pod-registry
import ..sdk
import ..ui
import ..utils
import ...service.run.simulate show run-host

PARTITION-OPTION ::= OptionPatterns "partition"
    ["file:<name>=<path>", "empty:<name>=<size>"]
    --help="Add a custom partition to the device."
    --split-commas
    --multi

create-serial-commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "serial"
      --help="Serial port commands."

  flash-options := [
    cli.Option "port"
        --short-name="p"
        --required,
    cli.Option "baud",
    PARTITION-OPTION,
  ]

  flash-cmd := cli.Command "flash"
      --help="""
        Flash a device with the firmware.

        The pod to flash on the device is found through the '$DEFAULT-GROUP' group
        or the specified '--group' in the current fleet.

        Unless '--no-default' is used, automatically makes this device the
        new default device.
        """
      --options=flash-options + [
        cli.Flag "default"
            --default=true
            --help="Make this device the default device.",
        cli.Option "name"
            --help="The name of the device.",
        cli.Option "group"
            --default=DEFAULT-GROUP
            --help="Add this device to a group.",
        cli.Option "local"
            --type="file"
            --help="A local pod file to flash.",
        cli.Flag "simulate"
            --hidden
            --default=false,
      ]
      --rest=[
        cli.Option "remote"
            --help="A remote pod reference; a UUID, name@tag, or name#revision.",
      ]
      --examples=[
        cli.Example """
            Flash the device on port /dev/ttyUSB0 with the pod for the default
            group and add the new identity to the devices file:"""
            --arguments="--port /dev/ttyUSB0"
            --global-priority=6,
        cli.Example """
            Flash the device on port /dev/ttyUSB0 with the pod for the 'production'
            group and add the new identity to the devices file in that group:"""
            --arguments="--port /dev/ttyUSB0 --group production",
        cli.Example """
            Flash the device on port /dev/ttyUSB0 with the pod for the 'production'
            group and add the new identity to the devices file in that group, but
            don't make it the default device:"""
            --arguments="--port /dev/ttyUSB0 --group production --no-default",
      ]
      --run=:: flash it config cache ui
  cmd.add flash-cmd

  flash-station-cmd := cli.Command "flash-station"
      --help="""
        Commands for a flash station.

        Flash stations are typically used to flash devices in a factory.
        They don't have Internet access and must work with prebuilt
        identities and firmware images.

        Flash station commands don't need any valid fleet root.
        """
  cmd.add flash-station-cmd

  flash-station-flash-cmd := cli.Command "flash"
      --help="""
        Flash a device on a flash station.

        Does not require Internet access, but uses identity files that have
        been prebuilt using 'fleet add-devices'.

        The 'port' argument is used to select the serial port to use.
        """
      --options=flash-options + [
        cli.Option "pod"
            --type="file"
            --help="The pod to flash."
            --required,
        cli.Option "identity"
            --type="file"
            --short-name="i"
            --help="The identity file to use."
            --required,
      ]
      --examples=[
        cli.Example """
            Flash the device on port /dev/ttyUSB0 with the pod 'my-pod.pod' and
            the identity '12345678-1234-1234-1234-123456789abc.identity':"""
            --arguments="--port /dev/ttyUSB0 --pod my-pod.pod --identity 12345678-1234-1234-1234-123456789abc.identity",
      ]
      --run=:: flash --station it config cache ui
  flash-station-cmd.add flash-station-flash-cmd

  return [cmd]

build-partitions-table_ partition-list/List --ui/Ui -> List:
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
        ui.error "Partition $type:$name refers to invalid file."
        ui.error "No such file: $value."
        ui.abort
    else:
      size := int.parse value --on-error=:
        ui.abort "Partition $type:$name has illegal size: '$it'."
      if size <= 0:
        ui.abort "Partition $type:$name has illegal size: $size."
    result.add "$type:$description"
  return result

flash parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  port := parsed["port"]
  baud := parsed["baud"]
  simulate := parsed["simulate"]
  should-make-default := parsed["default"]
  name := parsed["name"]
  group := parsed["group"]
  local := parsed["local"]
  remote := parsed["remote"]
  partitions := build-partitions-table_ parsed["partition"] --ui=ui

  if local and remote:
    ui.abort "Cannot specify both a local pod file and a remote pod reference."

  with-devices-fleet parsed config cache ui: | fleet/FleetWithDevices |
    artemis := fleet.artemis_

    with-tmp-directory: | tmp-dir/string |
      device-id := random-uuid
      identity-path := fleet.create-identity
          --id=device-id
          --name=name
          --group=group
          --output-directory=tmp-dir
      fleet-device := fleet.device device-id
      ui.info "Successfully provisioned device $fleet-device.name ($device-id)."

      pod/Pod := ?
      reference/PodReference := ?
      if local:
        pod = Pod.from-file local
            --organization-id=fleet.organization-id
            --artemis=artemis
            --ui=ui
        reference = PodReference --id=pod.id
      else:
        if remote:
          reference = PodReference.parse remote --allow-name-only --ui=ui
        else:
          reference = fleet.pod-reference-for-group group
        pod = fleet.download reference

      // Make unique for the given device.
      config-bytes := artemis.compute-device-specific-data
          --pod=pod
          --identity-path=identity-path

      config-path := "$tmp-dir/$(device-id).config"
      write-blob-to-file config-path config-bytes

      sdk := get-sdk pod.sdk-version --cache=cache
      if not simulate:
        ui.do --kind=Ui.VERBOSE: | printer/Printer|
          debug-line := "Flashing the device with pod $reference"
          if reference.id: debug-line += "."
          else: debug-line += " ($pod.id)."
          printer.emit debug-line
        // Flash.
        sdk.flash
            --envelope-path=pod.envelope-path
            --config-path=config-path
            --port=port
            --baud-rate=baud
            --partitions=partitions
        if should-make-default: make-default_ --device-id=device-id --config=config --ui=ui
        info := "Successfully flashed device $fleet-device.name ($device-id"
        if group: info += " in group '$group'"
        info += ") with pod '$reference'"
        if reference.id: info += "."
        else: info += " ($pod.id)."
        ui.info info
      else:
        ui.info "Simulating flash."
        ui.info "Using the local Artemis service and not the one specified in the specification."
        old-default := config.get CONFIG-ARTEMIS-DEFAULT-KEY
        if should-make-default: make-default_ --device-id=device-id --config=config --ui=ui
        run-host
            --pod=pod
            --identity-path=identity-path
            --cache=cache

      if ui.wants-structured-result:
        ui.result {
              "device_id": "$device-id",
              "pod_id": "$pod.id",
              "pod_name": "$pod.name",
              "group": "$group",
            }

flash --station/bool parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  if not station: throw "INVALID_ARGUMENT"
  identity-path := parsed["identity"]
  pod-path := parsed["pod"]
  port := parsed["port"]
  baud := parsed["baud"]
  partitions := build-partitions-table_ parsed["partition"] --ui=ui

  with-artemis parsed config cache ui: | artemis/Artemis |
    pod := Pod.parse pod-path --tmp-directory=artemis.tmp-directory --ui=ui
    with-tmp-directory: | tmp-dir/string |
      // Make unique for the given device.
      config-bytes := artemis.compute-device-specific-data
          --pod=pod
          --identity-path=identity-path

      config-path := "$tmp-dir/config"
      write-blob-to-file config-path config-bytes

      // Flash.
      sdk := get-sdk pod.sdk-version --cache=cache
      sdk.flash
          --envelope-path=pod.envelope-path
          --config-path=config-path
          --port=port
          --baud-rate=baud
          --partitions=partitions
      identity := read-base64-ubjson identity-path
      // TODO(florian): Abstract away the identity format.
      device-id := uuid.parse identity["artemis.device"]["device_id"]
      ui.info "Successfully flashed device $device-id with pod '$pod.name' ($pod.id)."
