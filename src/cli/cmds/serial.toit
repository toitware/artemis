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
import ...service.run.host show run-host

create-serial-commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "serial"
      --short-help="Serial port commands."

  flash-options := [
    cli.Option "port"
        --short-name="p"
        --required,
    cli.Option "baud",
    OptionPatterns "partition"
        ["file:<name>=<path>", "empty:<name>=<size>"]
        --short-help="Add a custom partition to the device."
        --split-commas
        --multi,
  ]

  flash-cmd := cli.Command "flash"
      --long-help="""
        Flashes a device with the firmware.

        The pod to flash on the device is found through the '$DEFAULT-GROUP' group
        or the specified '--group' in the current fleet.

        Unless '--no-default' is used, automatically makes this device the
        new default device.
        """
      --options=flash-options + [
        cli.Flag "default"
            --default=true
            --short-help="Make this device the default device.",
        cli.Option "group"
            --default=DEFAULT-GROUP
            --short-help="Add this device to a group.",
        cli.Option "local"
            --type="file"
            --short-help="A local pod file to flash.",
        cli.Flag "simulate"
            --hidden
            --default=false,
      ]
      --rest=[
        cli.Option "remote"
            --short-help="A remote pod reference; a UUID, name@tag, or name#revision.",
      ]
      --run=:: flash it config cache ui
  cmd.add flash-cmd

  flash-station-cmd := cli.Command "flash-station"
      --long-help="""
        Commands for a flash station.

        Flash stations are typically used to flash devices in a factory.
        They don't have Internet access and must work with prebuilt
        identities and firmware images.

        Flash station commands don't need any valid fleet root.
        """
  cmd.add flash-station-cmd

  flash-station-flash-cmd := cli.Command "flash"
      --long-help="""
        Flashes a device on a flash station.

        Does not require Internet access.

        The 'port' argument is used to select the serial port to use.
        """
      --options=flash-options + [
        cli.Option "pod"
            --type="file"
            --short-help="The pod to flash."
            --required,
        cli.Option "identity"
            --type="file"
            --short-name="i"
            --short-help="The identity file to use."
            --required,
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
  group := parsed["group"]
  local := parsed["local"]
  remote := parsed["remote"]
  partitions := build-partitions-table_ parsed["partition"] --ui=ui

  if local and remote:
    ui.abort "Cannot specify both a local pod file and a remote pod reference."

  with-fleet parsed config cache ui: | fleet/Fleet |
    artemis := fleet.artemis_

    with-tmp-directory: | tmp-dir/string |
      identity-path := fleet.create-identity
          --group=group
          --output-directory=tmp-dir
      identity := read-base64-ubjson identity-path
      // TODO(florian): Abstract away the identity format.
      device-id := uuid.parse identity["artemis.device"]["device_id"]
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
            --chip=pod.chip
        if should-make-default: make-default_ device-id config ui
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
        if should-make-default: make-default_ device-id config ui
        run-host
            --pod=pod
            --identity-path=identity-path
            --cache=cache

make-default_ device-id/uuid.Uuid config/Config ui/Ui:
  config[CONFIG-DEVICE-DEFAULT-KEY] = "$device-id"
  config.write
  ui.info "Default device set to $device-id."

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
      // TODO(florian): don't print anything if ui is quiet/silent.
      sdk.flash
          --envelope-path=pod.envelope-path
          --config-path=config-path
          --port=port
          --baud-rate=baud
          --partitions=partitions
          --chip=pod.chip
      identity := read-base64-ubjson identity-path
      // TODO(florian): Abstract away the identity format.
      device-id := uuid.parse identity["artemis.device"]["device_id"]
      ui.info "Successfully flashed device $device-id with pod '$pod.name' ($pod.id)."
