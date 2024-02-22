// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import encoding.base64
import uuid

import .utils_
import .device-container
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
import ..server-config
import ..ui
import ..utils
import ...shared.json-diff show Modification

create-device-commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "device"
      --help="Manage devices."
      --options=[
        cli.Option "device"
            --short-name="d"
            --help="ID, name or alias of the device.",
      ]

  update-cmd := cli.Command "update"
      --help="""
        Updates the firmware on a device.

        The firmware can be specified through a local pod file using '--local'
        or it can be a remote pod reference like name@tag or name#revision.
        """
      --options=[
        cli.Option "local"
            --type="file"
            --help="A local pod file to update to.",
      ]
      --rest=[
        cli.Option "remote"
            --help="A remote pod reference; a UUID, name@tag, or name#revision.",
      ]
      --examples=[
        cli.Example "Update the device big-whale with pod 'pressure@v1.2.3'"
            --arguments="-d big-whale pressure@v1.2.3",
        cli.Example "Update the default device (see 'device default') with the pod 'hibernate.pod':"
            --arguments="--local hibernate.pod",
        cli.Example """
            Update the device with UUID '62a99fbc-aac7-4af1-a09b-dfcece191d14' to the
            pod 'pressure#2':"""
            --arguments="-d 62a99fbc-aac7-4af1-a09b-dfcece191d14 pressure#2",
      ]
      --run=:: update it config cache ui
  cmd.add update-cmd

  default-cmd := cli.Command "default"
      --help="""
        Show or set the default device.

        If no ID is given, shows the current default device.
        If an ID is given, sets the default device.

        If the '--clear' flag is specified, clears the default device.
        """
      --options=[
        cli.Flag "id-only" --help="Only show the ID of the default device.",
        cli.Flag "clear"
            --help="Clear the default device.",
      ]
      --rest=[
        cli.Option "device-rest"
            --help="ID, name or alias of the device.",
      ]
      --examples=[
        cli.Example "Set the default device to big-whale:" --arguments="big-whale",
        cli.Example "Set the default device to the device with UUID '62a99fbc-aac7-4af1-a09b-dfcece191d14':"
            --arguments="62a99fbc-aac7-4af1-a09b-dfcece191d14",
        cli.Example "Show the default device:" --arguments="",
        cli.Example "Clear the default device:" --arguments="--clear",
      ]
      --run=:: default-device it config cache ui
  cmd.add default-cmd

  show-cmd := cli.Command "show"
      --aliases=["status"]
      --help="""
        Show all available information about a device.

        If no ID is given, shows the information of the default device.
        """
      --options=[
        cli.Option "event-type"
            --help="Only show events of this type."
            --multi,
        cli.Flag "show-event-values"
            --help="Show the values of the events."
            --default=false,
        cli.OptionInt "max-events"
            --help="Maximum number of events to show."
            --default=3,
      ]
      --rest=[
        cli.Option "device-rest"
            --help="ID, name or alias of the device.",
      ]
      --examples=[
        cli.Example "Show the status of the default device (see 'device default'):"
            --arguments="",
        cli.Example "Show the status of the device big-whale:"
            --arguments="big-whale",
        cli.Example "Show the status of the device with UUID '62a99fbc-aac7-4af1-a09b-dfcece191d14':"
            --arguments="62a99fbc-aac7-4af1-a09b-dfcece191d14",
        cli.Example "Show up to 20 events of the device big-whale:"
            --arguments="--max-events 20 big-whale",
      ]
      --run=:: show it config cache ui
  cmd.add show-cmd

  max-offline-cmd := cli.Command "set-max-offline"
      --help="Update the max-offline time of a device."
      --rest=[
        cli.Option "max-offline"
            --help="The new max-offline time."
            --type="duration"
            --required,
      ]
      --examples=[
        cli.Example "Set the max-offline time to 15 seconds" --arguments="15s",
        cli.Example "Set the max-offline time to 3 minutes" --arguments="3m",
      ]
      --run=:: set-max-offline it config cache ui
  cmd.add max-offline-cmd

  cmd.add (create-container-command config cache ui)
  return [cmd]

with-device
    parsed/cli.Parsed
    config/Config
    cache/Cache
    ui/Ui
    --allow-rest-device/bool=false
    [block]:
  device-reference := parsed["device"]

  if allow-rest-device:
    device-rest-reference := parsed["device-rest"]
    if device-reference and device-rest-reference:
      ui.abort "Cannot specify a device both with '-d' and without it: $device-reference, $device-rest-reference."

    if device-rest-reference: device-reference = device-rest-reference

  with-fleet parsed config cache ui: | fleet/Fleet |
    device/DeviceFleet := ?
    if not device-reference:
      device-id := default-device-from-config config
      if not device-id:
        ui.abort "No device specified and no default device ID set."
      device = fleet.device device-id
    else:
      device = fleet.resolve-alias device-reference

    block.call device fleet.artemis_ fleet

update parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device := parsed["device"]
  local := parsed["local"]
  remote := parsed["remote"]

  reference/PodReference? := null
  if local:
    if remote:
      ui.abort "Cannot specify both a local pod file and a remote pod reference."
  else if remote:
    reference = PodReference.parse remote --allow-name-only --ui=ui
  else:
    ui.abort "No pod specified."

  with-device parsed config cache ui: | device/DeviceFleet artemis/Artemis fleet/Fleet |
    pod/Pod := ?
    if reference:
      pod = fleet.download reference
    else:
      pod = Pod.from-file local
          --organization-id=fleet.organization-id
          --artemis=artemis
          --ui=ui
    artemis.update --device-id=device.id --pod=pod

default-device parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device-reference := parsed["device"]
  device-rest-reference := parsed["device-rest"]

  if parsed["clear"]:
    config.remove CONFIG-DEVICE-DEFAULT-KEY
    config.write
    ui.info "Default device cleared."
    return

  if device-reference and device-rest-reference:
    ui.abort "Cannot specify a device both with '-d' and without it: $device-reference, $device-rest-reference."

  with-fleet parsed config cache ui: | fleet/Fleet |
    // We allow to set the default with `-d` or by giving it as rest argument.
    device := device-reference or device-rest-reference
    device-id := ?
    if not device:
      // TODO(florian): make sure the device exists in the fleet.
      device-id = default-device-from-config config
      if not device-id:
        ui.abort "No default device set."

      ui.result "$device-id"
      return
    else:
      resolved := fleet.resolve-alias device
      device-id = resolved.id

    // TODO(florian): make sure the device exists on the broker.
    make-default_ device-id config ui

make-default_ device-id/uuid.Uuid config/Config ui/Ui:
  config[CONFIG-DEVICE-DEFAULT-KEY] = "$device-id"
  config.write
  ui.info "Default device set to $device-id."

show parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device-reference := parsed["device"]
  device-rest-reference := parsed["device-rest"]
  event-types := parsed["event-type"]
  show-event-values := parsed["show-event-values"]
  max-events := parsed["max-events"]

  if max-events < 0:
    ui.abort "max-events must be >= 0."

  with-device parsed config cache ui --allow-rest-device:
    | fleet-device/DeviceFleet artemis/Artemis fleet/Fleet |
      broker := artemis.connected-broker
      artemis-server := artemis.connected-artemis-server
      devices := broker.get-devices --device-ids=[fleet-device.id]
      if devices.is-empty:
        ui.abort "Device $device-reference does not exist on the broker."
      broker-device := devices[fleet-device.id]
      organization := artemis-server.get-organization broker-device.organization-id
      events/List? := null
      if max-events != 0:
        events-map := broker.get-events
                          --device-ids=[fleet-device.id]
                          --types=event-types.is-empty ? null : event-types
                          --limit=max-events

        events = events-map.get fleet-device.id
      ui.do: | printer/Printer |
        printer.emit-structured
          --json=: device-to-json_ fleet-device broker-device organization events
          --stdout=:
            print-device_
                --show-event-values=show-event-values
                fleet
                fleet-device
                broker-device
                organization
                events
                it

set-max-offline parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  max-offline := parsed["max-offline"]

  with-device parsed config cache ui: | device/DeviceFleet artemis/Artemis _ |
    max-offline-seconds := int.parse max-offline --on-error=:
      // Assume it's a duration with units, like "5s".
      duration := parse-duration max-offline --on-error=:
        ui.abort "Invalid max-offline duration: $max-offline."
      duration.in-s

    artemis.config-set-max-offline --device-id=device.id
          --max-offline-seconds=max-offline-seconds
    ui.info "Request sent to broker. Max offline time will be changed when device synchronizes."

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

print-device_
    --show-event-values/bool
    fleet/Fleet
    fleet-device/DeviceFleet
    broker-device/DeviceDetailed
    organization/OrganizationDetailed
    events/List?
    printer/Printer:
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
    printer.emit --title="Events" event-strings

print-map_ map/Map printer/Printer --indentation/int=0 --prefix/string="" --preferred-keys/List?=null:
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

print-list_ list/List printer/Printer --indentation/int=0:
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

print-modification_ modification/Modification --to/Map --fleet/Fleet printer/Printer:
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

print-app-update_ name/string from/Map to/Map printer/Printer:
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

firmware-to-pod-description_ --fleet/Fleet encoded-firmware/string -> string:
  firmware := Firmware.encoded encoded-firmware
  pod-id := firmware.pod-id
  fleet-pod := fleet.pod pod-id
  if not fleet-pod.name: return "$pod-id"
  return "$pod-id - $fleet-pod.name#$fleet-pod.revision $(fleet-pod.tags.join ",")"
