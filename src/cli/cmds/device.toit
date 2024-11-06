// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show *
import encoding.base64
import encoding.ubjson
import host.file
import uuid show Uuid

import .utils_
import .device-container
import .serial show PARTITION-OPTION
import ..artemis
import ..cache
import ..config
import ..device
import ..event
import ..fleet
import ..firmware
import ..organization
import ..pod
import ..pod-registry
import ..pod-specification
import ..sdk
import ..server-config
import ..utils
import ...shared.json-diff show Modification

EXTRACT-FORMATS-COMMAND-HELP ::= """
  This command supports the following output formats:
    - 'identity': an identity file.
    - 'binary': a binary image suitable for OTA updates.
    - 'tar': a tar file with the device firmware. Only available for host devices.
      That is, devices that use an envelope built for Linux, macOS, or Windows.
    - 'image': a binary image suitable for QEMU, Wokwi, or flashing
      a device. Only available for the ESP32 chip family. See the help of
      'toit tool firmware extract' for more information.
    - 'qemu': a deprecated alias for 'image'.

  The type of device (host, ESP32, etc.) is determined by the pod of the group
  the device is in.

  The '--partition' option is only used for formats that emit a full
  image, like "qemu".
  """

build-extract-format-options --required/bool -> List:
  return [
    OptionEnum "format" ["identity", "binary", "tar", "image", "qemu"]
        --help="The format of the output file."
        --required=required,
    PARTITION-OPTION
  ]

create-device-commands -> List:
  cmd := Command "device"
      --help="Manage devices."
      --options=[
        Option "device"
            --short-name="d"
            --help="ID, name or alias of the device.",
      ]

  update-cmd := Command "update"
      --help="""
        Updates the firmware on a device.

        The firmware can be specified through a local pod file using '--local'
        or it can be a remote pod reference like name@tag or name#revision.
        """
      --options=[
        Option "local"
            --type="file"
            --help="A local pod file to update to.",
      ]
      --rest=[
        Option "remote"
            --help="A remote pod reference; a UUID, name@tag, or name#revision.",
      ]
      --examples=[
        Example "Update the device big-whale with pod 'pressure@v1.2.3'"
            --arguments="-d big-whale pressure@v1.2.3",
        Example "Update the default device (see 'device default') with the pod 'hibernate.pod':"
            --arguments="--local hibernate.pod",
        Example """
            Update the device with UUID '62a99fbc-aac7-4af1-a09b-dfcece191d14' to the
            pod 'pressure#2':"""
            --arguments="-d 62a99fbc-aac7-4af1-a09b-dfcece191d14 pressure#2",
      ]
      --run=:: update it
  cmd.add update-cmd

  default-cmd := Command "default"
      --help="""
        Show or set the default device.

        If no ID is given, shows the current default device.
        If an ID is given, sets the default device.

        If the '--clear' flag is specified, clears the default device.
        """
      --options=[
        Flag "id-only" --help="Only show the ID of the default device.",
        Flag "clear"
            --help="Clear the default device.",
      ]
      --rest=[
        Option "device-rest"
            --help="ID, name or alias of the device.",
      ]
      --examples=[
        Example "Set the default device to big-whale:" --arguments="big-whale",
        Example "Set the default device to the device with UUID '62a99fbc-aac7-4af1-a09b-dfcece191d14':"
            --arguments="62a99fbc-aac7-4af1-a09b-dfcece191d14",
        Example "Show the default device:" --arguments="",
        Example "Clear the default device:" --arguments="--clear",
      ]
      --run=:: default-device it
  cmd.add default-cmd

  show-cmd := Command "show"
      --aliases=["status"]
      --help="""
        Show all available information about a device.

        If no ID is given, shows the information of the default device.
        """
      --options=[
        Option "event-type"
            --help="Only show events of this type."
            --multi,
        Flag "show-event-values"
            --help="Show the values of the events."
            --default=false,
        OptionInt "max-events"
            --help="Maximum number of events to show."
            --default=3,
      ]
      --rest=[
        Option "device-rest"
            --help="ID, name or alias of the device.",
      ]
      --examples=[
        Example "Show the status of the default device (see 'device default'):"
            --arguments="",
        Example "Show the status of the device big-whale:"
            --arguments="big-whale",
        Example "Show the status of the device with UUID '62a99fbc-aac7-4af1-a09b-dfcece191d14':"
            --arguments="62a99fbc-aac7-4af1-a09b-dfcece191d14",
        Example "Show up to 20 events of the device big-whale:"
            --arguments="--max-events 20 big-whale",
      ]
      --run=:: show it
  cmd.add show-cmd

  max-offline-cmd := Command "set-max-offline"
      --help="Update the max-offline time of a device."
      --rest=[
        Option "max-offline"
            --help="The new max-offline time."
            --type="duration"
            --required,
      ]
      --examples=[
        Example "Set the max-offline time to 15 seconds" --arguments="15s",
        Example "Set the max-offline time to 3 minutes" --arguments="3m",
      ]
      --run=:: set-max-offline it
  cmd.add max-offline-cmd

  cmd.add create-container-command

  extract-cmd := Command "extract"
      --help="""
        Extracts a representation of this device.

        $EXTRACT-FORMATS-COMMAND-HELP

        If no pod is specified, the one specified in the fleet is used.
        """
      --options= (build-extract-format-options --required) + [
        Option "output"
            --short-name="o"
            --type="file"
            --help="The output file."
            --required,
        Option "local"
            --help="A local pod file to build the firmware from.",
        Option "remote"
            --help="A remote reference to a pod to build the firmware from.",
        Flag "force"
            --help="Force the extraction even if OTA partition is small."
            --default=false,
      ]
      --rest=[
        Option "device-rest"
            --help="ID, name or alias of the device.",
      ]
      --examples=[
        Example "Build a firmware image for the default device (see 'device default'):"
            --arguments="--format binary --output firmware.ota",
        Example "Build a firmware image for the device big-whale:"
            --arguments="--format binary --output firmware.ota big-whale",
        Example "Build a tarball with the necessary files to run the firmware for the default device:"
            --arguments="--format tar --output firmware.tar",
      ]
      --run=:: extract-device it
  cmd.add extract-cmd

  return [cmd]

with-device invocation/Invocation --allow-rest-device/bool=false [block]:
  cli := invocation.cli
  ui := cli.ui

  device-reference := invocation["device"]

  if allow-rest-device:
    device-rest-reference := invocation["device-rest"]
    if device-reference and device-rest-reference:
      ui.abort "Cannot specify a device both with '-d' and without it: '$device-reference', '$device-rest-reference'."

    if device-rest-reference: device-reference = device-rest-reference

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    device/DeviceFleet := ?
    if not device-reference:
      device-id := default-device-from-config --cli=cli
      if not device-id:
        ui.abort "No device specified and no default device ID set."
      device = fleet.device device-id
    else:
      device = fleet.resolve-alias device-reference

    block.call device fleet

pod-for_ -> Pod?
    --local/string?
    --remote/string?
    --fleet/FleetWithDevices
    --cli/Cli
    [--on-absent]:
  reference/PodReference? := null
  if local:
    if remote:
      cli.ui.abort "Cannot specify both a local pod file and a remote pod reference."
  else if remote:
    reference = PodReference.parse remote --allow-name-only --cli=cli
  else:
    return on-absent.call

  if reference:
    return fleet.download reference

  return Pod.from-file local
      --organization-id=fleet.organization-id
      --recovery-urls=fleet.recovery-urls
      --artemis=fleet.artemis
      --broker=fleet.broker
      --cli=cli

update invocation/Invocation:
  device := invocation["device"]
  local := invocation["local"]
  remote := invocation["remote"]

  cli := invocation.cli
  ui := cli.ui

  with-device invocation: | device/DeviceFleet fleet/FleetWithDevices |
    pod := pod-for_ --local=local --remote=remote --fleet=fleet --cli=cli --on-absent=:
      ui.abort "No pod specified."
    fleet.update --device-id=device.id --pod=pod
    ui.emit --info "Update request sent to broker. The device will update when it synchronizes."
    ui.emit
        --kind=Ui.RESULT
        --structured=: {
          "device-id": "$device.id",
          "pod-id": "$pod.id",
        }
        --text=:
          // Don't output anything.
          null

default-device invocation/Invocation:
  device-reference := invocation["device"]
  device-rest-reference := invocation["device-rest"]

  cli := invocation.cli
  config := cli.config
  ui := cli.ui

  if invocation["clear"]:
    config.remove CONFIG-DEVICE-DEFAULT-KEY
    config.write
    ui.emit --info "Default device cleared."
    return

  if device-reference and device-rest-reference:
    ui.abort "Cannot specify a device both with '-d' and without it: '$device-reference', '$device-rest-reference'."

  with-devices-fleet invocation: | fleet/FleetWithDevices |
    // We allow to set the default with `-d` or by giving it as rest argument.
    device := device-reference or device-rest-reference
    device-id := ?
    if not device:
      // TODO(florian): make sure the device exists in the fleet.
      device-id = default-device-from-config --cli=cli
      if not device-id:
        ui.abort "No default device set."

      ui.emit --result "$device-id"
      return
    else:
      resolved := fleet.resolve-alias device
      device-id = resolved.id

    // TODO(florian): make sure the device exists on the broker.
    make-default_ device-id --cli=cli

make-default_ device-id/Uuid --cli/Cli:
  cli.config[CONFIG-DEVICE-DEFAULT-KEY] = "$device-id"
  cli.config.write
  cli.ui.emit --info "Default device set to $device-id."

show invocation/Invocation:
  params := invocation.parameters
  device-reference := params["device"]
  device-rest-reference := params["device-rest"]
  event-types := params["event-type"]
  show-event-values := params["show-event-values"]
  max-events := params["max-events"]

  cli := invocation.cli
  ui := cli.ui

  if max-events < 0:
    ui.abort "max-events must be >= 0."

  with-device invocation --allow-rest-device: | fleet-device/DeviceFleet fleet/FleetWithDevices |
      broker := fleet.broker
      devices := broker.get-devices --device-ids=[fleet-device.id]
      if devices.is-empty:
        ui.abort "Device '$device-reference' does not exist on the broker."
      broker-device := devices[fleet-device.id]
      organization := fleet.artemis.get-organization --id=broker-device.organization-id
      events/List? := null
      if max-events != 0:
        events-map := broker.get-events
                          --device-ids=[fleet-device.id]
                          --types=event-types.is-empty ? null : event-types
                          --limit=max-events

        events = events-map.get fleet-device.id
      ui.emit --kind=Ui.RESULT
          --structured=: device-to-json_ fleet-device broker-device organization events
          --text=:
            print-device_
                --show-event-values=show-event-values
                fleet
                fleet-device
                broker-device
                organization
                events

set-max-offline invocation/Invocation:
  max-offline := invocation["max-offline"]

  ui := invocation.cli.ui

  with-device invocation: | device/DeviceFleet fleet/FleetWithDevices |
    max-offline-seconds := int.parse max-offline --on-error=:
      // Assume it's a duration with units, like "5s".
      duration := parse-duration max-offline --on-error=:
        ui.abort "Invalid max-offline duration: $max-offline."
      duration.in-s

    fleet.broker.config-set-max-offline --device-id=device.id
          --max-offline-seconds=max-offline-seconds
    ui.emit --info "Request sent to broker. Max offline time will be changed when device synchronizes."

extract-device invocation/Invocation:
  params := invocation.parameters
  output := params["output"]
  format := params["format"]
  local := params["local"]
  remote := params["remote"]
  partitions := params["partition"]
  force := params["force"]

  cli := invocation.cli
  ui := cli.ui

  with-device invocation: | fleet-device/DeviceFleet fleet/FleetWithDevices |
    pod/Pod? := null
    if local or remote:
      pod = pod-for_
          --local=local
          --remote=remote
          --fleet=fleet
          --on-absent=: unreachable
          --cli=cli
    extract-device fleet-device
        --fleet=fleet
        --pod=pod
        --format=format
        --output=output
        --partitions=partitions
        --force=force
        --cli=cli
    ui.emit --info "Firmware successfully written to '$output'."

extract-device fleet-device/DeviceFleet
    --fleet/FleetWithDevices
    --pod/Pod?=null
    --identity-path/string?=null
    --format/string
    --output/string
    --partitions/List
    --force/bool
    --cli/Cli:
  ui := cli.ui

  artemis := fleet.artemis

  device/Device := identity-path
      ? FleetWithDevices.device-from --identity-path=identity-path
      : fleet.broker.device-for --id=fleet-device.id

  if format == "identity":
    if not identity-path:
      fleet.write-identity-file device --out-path=output
    else:
      file.copy --source=identity-path --target=output
    cli.ui.emit --info "Wrote identity to '$output'."
    return

  if not pod: pod = fleet.pod-for fleet-device

  firmware := Firmware --device=device --pod=pod --cli=cli
  sdk := get-sdk pod.sdk-version --cli=cli
  with-tmp-directory: | tmp-dir/string |
    device-specific-path := "$tmp-dir/device-specific"
    device-specific := firmware.device-specific-data
    file.write-content --path=device-specific-path device-specific

    if format == "tar" or format == "binary":
      bytes := sdk.firmware-extract
          --format=format
          --envelope-path=pod.envelope-path
          --device-specific-path=device-specific-path
      file.write-content --path=output bytes
      if format == "tar":
        ui.emit --info "Wrote tarball to '$output'."
      else:
        ui.emit --info "Wrote binary firmware to '$output'."
    else if format == "qemu" or format == "image":
      if format == "qemu":
        ui.emit --warning "The 'qemu' format is deprecated. Use 'image' instead."
      chip-family := Sdk.get-chip-family-from --envelope=pod.envelope
      if chip-family != "esp32":
        ui.abort "Cannot generate binary image for chip-family '$chip-family'."
      chip := sdk.chip-for --envelope-path=pod.envelope-path
      if chip != "esp32":
        ui.abort "Cannot generate binary image for chip '$chip'."
      check-esp32-partition-size_ pod --ui=ui --force=force

      sdk.extract-image
          --output-path=output
          --envelope-path=pod.envelope-path
          --config-path=device-specific-path
          --partitions=partitions
      ui.emit --info "Wrote binary image to '$output'."
    else:
      ui.abort "Unknown format: $format."

device-to-json_
    fleet-device/DeviceFleet
    broker-device/DeviceDetailed
    organization/OrganizationDetailed
    events/List?:
  result := {
    "id": "$broker-device.id",
    "name": fleet-device.name,
    "aliases": fleet-device.aliases,
    "organization_id": "$broker-device.organization-id",
    "organization_name": organization.name,
    "goal": broker-device.goal,
    "reported_state_goal": broker-device.reported-state-goal,
    "reported_state_current": broker-device.reported-state-current,
    "reported_state_firmware": broker-device.reported-state-firmware,
  }
  if events:
    result["events"] = events.map: | event/Event | event.to-json
  return result

is-sensitive_ name/string -> bool:
  return name.ends-with "password" or name.ends-with "key"

filter-sensitive_ o/any -> any:
  if o is Map:
    return o.map: | key value |
      if is-sensitive_ key: "***"
      else: filter-sensitive_ value
  if o is List:
    return o.map: | value | filter-sensitive_ value
  return o

class Printer_:
  chunks_ := []
  emit str/string:
    chunks_.add str

  to-string -> string:
    return chunks_.join "\n"

print-device_ -> string
    --show-event-values/bool
    fleet/FleetWithDevices
    fleet-device/DeviceFleet
    broker-device/DeviceDetailed
    organization/OrganizationDetailed
    events/List?:
  printer := Printer_
  printer.emit "Device ID: $broker-device.id"
  printer.emit "Organization ID: $broker-device.organization-id ($organization.name)"
  printer.emit "Device name: $(fleet-device.name or "")"
  aliases := fleet-device.aliases or []
  printer.emit "Device aliases: $(aliases.join ", ")"

  if broker-device.reported-state-firmware:
    printer.emit ""
    printer.emit "Firmware state as reported by the device:"
    state := broker-device.reported-state-firmware
    if state["firmware"]:
      state = state.copy
      pod-description/string? := null
      pod-description = firmware-to-pod-description_ --fleet=fleet state["firmware"]
      state["pod"] = pod-description
      state.remove "firmware"
    print-map_ state printer --indentation=2
        --preferred-keys=["sdk-version", "max-offline", "pod", "connections", "apps"]

  if broker-device.pending-firmware:
    printer.emit ""
    printer.emit "Pod installed but not running (pending a reboot):"
    printer.emit "   $(firmware-to-pod-description_ --fleet=fleet broker-device.pending-firmware)"

  if broker-device.reported-state-current:
    modification := Modification.compute
        --from=broker-device.reported-state-firmware
        --to=broker-device.reported-state-current
    if modification:
      printer.emit ""
      printer.emit "Current state modifications as reported by the device:"
      print-modification_ modification --to=broker-device.reported-state-current printer --fleet=fleet

  if broker-device.reported-state-goal:
    diff-to := broker-device.reported-state-current or broker-device.reported-state-firmware
    modification := Modification.compute
        --from=diff-to
        --to=broker-device.reported-state-goal
    printer.emit ""
    printer.emit "Goal state modifications compared to the current state as reported by the device:"
    print-modification_ modification --to=broker-device.reported-state-goal printer --fleet=fleet

  if broker-device.goal:
    if not broker-device.reported-state-firmware:
      // Hasn't checked in yet.
      printer.emit ""
      printer.emit "Goal state:"
      prettified := broker-device.goal.map: | key value |
        if key == "firmware": prettify-firmware value
        else: value
      print-map_ prettified printer --indentation=2
    else:
      diff-to/Map := ?
      diff-to-string/string := ?

      if broker-device.reported-state-goal:
        diff-to = broker-device.reported-state-goal
        diff-to-string = "reported goal state"
      else if broker-device.reported-state-current:
        diff-to = broker-device.reported-state-current
        diff-to-string = "reported current state"
      else:
        diff-to = broker-device.reported-state-firmware
        diff-to-string = "reported firmware state"

      modification := Modification.compute
          --from=diff-to
          --to=broker-device.goal
      if modification == null:
        printer.emit ""
        printer.emit "Goal is the same as the $diff-to-string."
      else:
        printer.emit ""
        printer.emit "Goal modifications compared to the $diff-to-string:"
        print-modification_ modification --to=broker-device.goal printer --fleet=fleet

  if events:
    printer.emit ""
    now := Time.now.local
    are-all-today := events.every: | event/Event |
      event-time := event.timestamp.local
      event-time.year == now.year and event-time.month == now.month and event-time.day == now.day

    event-to-string := : | event/Event |
      event-time := event.timestamp.local
      str/string := ""
      if not are-all-today:
        str += "$event-time.year-$(%02d event-time.month)-$(%02d event-time.day) "

      str += "$(%02d event-time.h):$(%02d event-time.m):$(%02d event-time.s)"
      str += ".$(%03d event-time.ns / 1000_000)"  // Only show milliseconds.
      str += " $event.type"
      if show-event-values:
        str += ": $event.data"
      str

    event-strings := events.map: event-to-string.call it
    printer.emit "Events:"
    event-strings.do: | event-string/string |
      printer.emit "  $event-string"

  return printer.to-string

print-map_ map/Map printer/Printer_ --indentation/int=0 --prefix/string="" --preferred-keys/List?=null:
  first-indentation-str := " " * indentation + prefix
  next-indentation-str := " " * first-indentation-str.size
  nested-indentation := first-indentation-str.size + 2
  is-first := true

  already-printed := {}
  print-key-value := : | key/string value |
    if not already-printed.contains key:
      already-printed.add key
      if is-sensitive_ key and value is string:
        value = "***"
      indentation-str := is-first ? first-indentation-str : next-indentation-str
      is-first = false
      if value is Map:
        printer.emit "$indentation-str$key:"
        print-map_ value printer --indentation=nested-indentation
      else if value is List:
        printer.emit "$indentation-str$key: ["
        print-list_ value printer --indentation=nested-indentation
        printer.emit "$indentation-str]"
      else:
        printer.emit "$indentation-str$key: $value"

  if preferred-keys:
    preferred-keys.do: | key |
      if map.contains key:
        print-key-value.call key map[key]

  keys := map.keys.sort
  keys.do: | key |
    print-key-value.call key map[key]

print-list_ list/List printer/Printer_ --indentation/int=0:
  indentation-str := " " * indentation
  nested-indentation := indentation + 2
  list.do: | value |
    if value is Map:
      print-map_ value printer --indentation=indentation  --prefix="* "
    else if value is List:
      printer.emit "$(indentation-str)* ["
      print-list_ value printer --indentation=nested-indentation
      printer.emit "$(indentation-str)]"
    else:
      printer.emit "$indentation-str* $value"

print-modification_ modification/Modification --to/Map --fleet/FleetWithDevices printer/Printer_:
  modification.on-value "firmware"
      --added=: printer.emit   "  +pod: $(firmware-to-pod-description_ it --fleet=fleet)"
      --removed=: printer.emit "  -pod"
      --updated=: | _ to | printer.emit "  pod -> $(firmware-to-pod-description_ to --fleet=fleet)"

  modification.on-value "max-offline"
      --added=: printer.emit   "  +max-offline: $it"
      --removed=: printer.emit "  -max-offline"
      --updated=: | _ to | printer.emit "  max-offline -> $to"

  has-app-changes := false
  modification.on-value "apps"
      --added=: has-app-changes = true
      --removed=: has-app-changes = true
      --updated=: has-app-changes = true

  if has-app-changes:
    printer.emit "  apps:"
    modification.on-map "apps"
        --added=: | name description |
          printer.emit "    +$name ($description)"
        --removed=: | name _ |
          printer.emit "    -$name"
        --updated=: | name from to |
          print-app-update_ name from to printer

  already-handled := { "firmware", "max-offline", "apps" }
  modification.on-map
      --added=: | name new-value |
        if already-handled.contains name: continue.on-map
        if is-sensitive_ name and new-value is string:
          new-value = "***"
        printer.emit "  +$name: $new-value"
      --removed=: | name _ |
        if already-handled.contains name: continue.on-map
        printer.emit "  -$name"
      --updated=: | name _ new-value |
        if already-handled.contains name: continue.on-map
        if is-sensitive_ name and new-value is string:
          new-value = "***"
        new-value = filter-sensitive_ new-value
        printer.emit "  $name -> $new-value"
      --modified=: | name _ |
        if already-handled.contains name: continue.on-map
        new-value := to[name]
        if is-sensitive_ name and new-value is string:
          new-value = "***"
        printer.emit "  $name changed to $new-value"

print-app-update_ name/string from/Map to/Map printer/Printer_:
  printer.emit "    $name:"
  modification := Modification.compute --from=from --to=to
  modification.on-map
      --added=: | key value |
        printer.emit "      +$key: $value"
      --removed=: | key _ |
        printer.emit "      -$key"
      --updated=: | key from to |
        printer.emit "      $key -> $to"

prettify-firmware firmware/string -> string:
  if firmware.size <= 80: return firmware
  return firmware[0..40] + "..." + firmware[firmware.size - 40..]

firmware-to-pod-description_ --fleet/FleetWithDevices encoded-firmware/string -> string:
  firmware := Firmware.encoded encoded-firmware
  pod-id := firmware.pod-id
  fleet-pod := fleet.pod pod-id
  if not fleet-pod.name: return "$pod-id"
  return "$pod-id - $fleet-pod.name#$fleet-pod.revision $(fleet-pod.tags.join ",")"
