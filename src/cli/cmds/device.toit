// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import encoding.base64
import uuid

import .utils_
import .device_container
import ..artemis
import ..cache
import ..config
import ..device
import ..event
import ..fleet
import ..firmware
import ..organization
import ..pod_specification
import ..server_config
import ..ui
import ..utils
import ...shared.json_diff show Modification

create_device_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "device"
      --short_help="Manage devices."
      --options=[
        cli.Option "device"
            --short_name="d"
            --short_help="ID, name or alias of the device.",
      ]

  update_cmd := cli.Command "update"
      --long_help="""
        Updates the firmware on the device.

        The specification file contains the pod specification. It includes
        the firmware version, installed applications, connection settings,
        etc. See 'doc specification-format' for more information.
        """
      --options=[
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the pod."
            --required,
      ]
      --run=:: update it config cache ui
  cmd.add update_cmd

  default_cmd := cli.Command "default"
      --long_help="""
        Show or set the default device.

        If no ID is given, shows the current default device.
        If an ID is given, sets the default device.

        If the '--clear' flag is specified, clears the default device.
        """
      --options=[
        cli.Flag "id-only" --short_help="Only show the ID of the default device.",
        cli.Flag "clear"
            --short_help="Clear the default device.",
      ]
      --rest=[
        OptionUuid "device"
            --short_help="ID, name or alias of the device.",
      ]
      --run=:: default_device it config cache ui
  cmd.add default_cmd

  show_cmd := cli.Command "show"
      --aliases=["status"]
      --long_help="""
        Show all available information about a device.

        If no ID is given, shows the information of the default device.
        """
      --options=[
        cli.Option "event-type"
            --short_help="Only show events of this type."
            --multi,
        cli.Flag "show-event-values"
            --short_help="Show the values of the events."
            --default=false,
        cli.OptionInt "max-events"
            --short_help="Maximum number of events to show."
            --default=3,
      ]
      --run=:: show it config cache ui
  cmd.add show_cmd

  max_offline_cmd := cli.Command "set-max-offline"
      --short_help="Update the max-offline time of the device."
      --rest=[
        cli.Option "max-offline"
            --short_help="The new max-offline time."
            --type="duration"
            --required,
      ]
      --examples=[
        cli.Example "Set the max-offline time to 15 seconds" --arguments="15",
        cli.Example "Set the max-offline time to 3 minutes" --arguments="3m",
      ]
      --run=:: set_max_offline it config cache ui
  cmd.add max_offline_cmd

  cmd.add (create_container_command config cache ui)
  return [cmd]

with_device parsed/cli.Parsed config/Config cache/Cache ui/Ui [block]:
  device_designation := parsed["device"]
  fleet_root := parsed["fleet-root"]

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache
    device/DeviceFleet := ?
    if not device_designation:
      device_id := default_device_from_config config
      if not device_id:
        ui.abort "No device specified and no default device ID set."
      device = fleet.device device_id
    else:
      device = fleet.resolve_alias device_designation

    block.call device artemis fleet

update parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device := parsed["device"]
  fleet_root := parsed["fleet-root"]
  specification_path := parsed["specification"]

  with_device parsed config cache ui: | device/DeviceFleet artemis/Artemis _ |
    specification := parse_pod_specification_file specification_path --ui=ui
    artemis.update --device_id=device.id --specification=specification

default_device parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  fleet_root := parsed["fleet-root"]

  if parsed["clear"]:
    config.remove CONFIG_DEVICE_DEFAULT_KEY
    config.write
    ui.info "Default device cleared."
    return

  with_artemis parsed config cache ui: | artemis/Artemis |
    fleet := Fleet fleet_root artemis --ui=ui --cache=cache

    // We allow to set the default with `-d` or by giving an ID as rest argument.
    device := parsed["device"] or parsed["id"]
    device_id := ?
    if not device:
      device_id = default_device_from_config config
      if not device_id:
        ui.abort "No default device set."

      ui.info "$device_id"
      return
    else:
      device_id = fleet.resolve_alias device

    // TODO(florian): make sure the device exists.
    make_default_ device_id config ui

make_default_ device_id/uuid.Uuid config/Config ui/Ui:
  config[CONFIG_DEVICE_DEFAULT_KEY] = "$device_id"
  config.write
  ui.info "Default device set to $device_id."

show parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device_designation := parsed["device"]
  event_types := parsed["event-type"]
  fleet_root := parsed["fleet-root"]
  show_event_values := parsed["show-event-values"]
  max_events := parsed["max-events"]

  if max_events < 0:
    ui.abort "max-events must be >= 0."

  with_device parsed config cache ui: | fleet_device/DeviceFleet artemis/Artemis fleet/Fleet |
    broker := artemis.connected_broker
    artemis_server := artemis.connected_artemis_server
    devices := broker.get_devices --device_ids=[fleet_device.id]
    if devices.is_empty:
      ui.abort "Device $device_designation does not exist on the broker."
    broker_device := devices[fleet_device.id]
    organization := artemis_server.get_organization broker_device.organization_id
    events/List? := null
    if max_events != 0:
      events_map := broker.get_events
                        --device_ids=[fleet_device.id]
                        --types=event_types.is_empty ? null : event_types
                        --limit=max_events

      events = events_map.get fleet_device.id
    ui.info_structured
        --json=: device_to_json_ fleet_device broker_device organization events
        --stdout=:
          print_device_
              --show_event_values=show_event_values
              fleet_device
              broker_device
              organization
              events
              it

set_max_offline parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  max_offline := parsed["max-offline"]

  with_device parsed config cache ui: | device/DeviceFleet artemis/Artemis _ |
    max_offline_seconds := int.parse max_offline --on_error=:
      // Assume it's a duration with units, like "5s".
      duration := parse_duration max_offline --on_error=:
        ui.abort "Invalid max-offline duration: $max_offline."
      duration.in_s

    artemis.config_set_max_offline --device_id=device.id
          --max_offline_seconds=max_offline_seconds
    ui.info "Request sent to broker. Max offline time will be changed when device synchronizes."

device_to_json_
    fleet_device/DeviceFleet
    broker_device/DeviceDetailed
    organization/OrganizationDetailed
    events/List?:
  result := {
    "id": "$broker_device.id",
    "organization_id": "$broker_device.organization_id",
    "organization_name": organization.name,
    "goal": broker_device.goal,
    "reported_state_goal": broker_device.reported_state_goal,
    "reported_state_current": broker_device.reported_state_current,
    "reported_state_firmware": broker_device.reported_state_firmware,
    "name": fleet_device.name,
    "aliases": fleet_device.aliases,
  }
  if events:
    result["events"] = events.map: | event/Event | event.to_json
  return result

is_sensitive_ name/string -> bool:
  return name.ends_with "password" or name.ends_with "key"

filter_sensitive_ o/any -> any:
  if o is Map:
    return o.map: | key value |
      if is_sensitive_ key: "***"
      else: filter_sensitive_ value
  if o is List:
    return o.map: | value | filter_sensitive_ value
  return o

print_device_
    --show_event_values/bool
    fleet_device/DeviceFleet
    broker_device/DeviceDetailed
    organization/OrganizationDetailed
    events/List?
    ui/Ui:
  ui.print "Device ID: $broker_device.id"
  ui.print "Organization ID: $broker_device.organization_id ($organization.name)"
  ui.print "Device name: $(fleet_device.name or "")"
  aliases := fleet_device.aliases or []
  ui.print "Device aliases: $(aliases.join ", ")"

  if broker_device.reported_state_firmware:
    ui.print ""
    ui.print "Firmware state as reported by the device:"
    prettified := broker_device.reported_state_firmware.map: | key value |
      if key == "firmware": prettify_firmware value
      else: value
    print_map_ prettified ui --indentation=2
        --preferred_keys=["sdk-version", "max-offline", "firmware", "connections", "apps"]


  if broker_device.pending_firmware:
    ui.print ""
    ui.print "Firmware installed but not running (pending a reboot):"
    ui.print "   $(prettify_firmware broker_device.pending_firmware)"

  if broker_device.reported_state_current:
    modification := Modification.compute
        --from=broker_device.reported_state_firmware
        --to=broker_device.reported_state_current
    if modification:
      ui.print ""
      ui.print "Current state modifications as reported by the device:"
      print_modification_ modification --to=broker_device.reported_state_current ui

  if broker_device.reported_state_goal:
    diff_to := broker_device.reported_state_current or broker_device.reported_state_firmware
    modification := Modification.compute
        --from=diff_to
        --to=broker_device.reported_state_goal
    ui.print ""
    ui.print "Goal state modifications compared to the current state as reported by the device:"
    print_modification_ modification --to=broker_device.reported_state_goal ui

  if broker_device.goal:
    if not broker_device.reported_state_firmware:
      // Hasn't checked in yet.
      ui.print ""
      ui.print "Goal state:"
      prettified := broker_device.goal.map: | key value |
        if key == "firmware": prettify_firmware value
        else: value
      print_map_ prettified ui --indentation=2
    else:
      diff_to/Map := ?
      diff_to_string/string := ?

      if broker_device.reported_state_goal:
        diff_to = broker_device.reported_state_goal
        diff_to_string = "reported goal state"
      else if broker_device.reported_state_current:
        diff_to = broker_device.reported_state_current
        diff_to_string = "reported current state"
      else:
        diff_to = broker_device.reported_state_firmware
        diff_to_string = "reported firmware state"

      modification := Modification.compute
          --from=diff_to
          --to=broker_device.goal
      if modification == null:
        ui.print ""
        ui.print "Goal is the same as the $diff_to_string."
      else:
        ui.print ""
        ui.print "Goal modifications compared to the $diff_to_string:"
        print_modification_ modification --to=broker_device.goal ui

  if events:
    ui.print ""
    now := Time.now.local
    are_all_today := events.every: | event/Event |
      event_time := event.timestamp.local
      event_time.year == now.year and event_time.month == now.month and event_time.day == now.day

    event_to_string := : | event/Event |
      event_time := event.timestamp.local
      str/string := ""
      if not are_all_today:
        str += "$event_time.year-$(%02d event_time.month)-$(%02d event_time.day) "

      str += "$(%02d event_time.h):$(%02d event_time.m):$(%02d event_time.s)"
      str += ".$(%03d event_time.ns / 1000_000)"  // Only show milliseconds.
      str += " $event.type"
      if show_event_values:
        str += ": $event.data"
      str

    event_strings := events.map: event_to_string.call it
    ui.info_list --title="Events" event_strings

print_map_ map/Map ui/Ui --indentation/int=0 --prefix/string="" --preferred_keys/List?=null:
  first_indentation_str := " " * indentation + prefix
  next_indentation_str := " " * first_indentation_str.size
  nested_indentation := first_indentation_str.size + 2
  is_first := true

  already_printed := {}
  print_key_value := : | key/string value |
    if not already_printed.contains key:
      already_printed.add key
      if is_sensitive_ key and value is string:
        value = "***"
      indentation_str := is_first ? first_indentation_str : next_indentation_str
      is_first = false
      if value is Map:
        ui.print "$indentation_str$key:"
        print_map_ value ui --indentation=nested_indentation
      else if value is List:
        ui.print "$indentation_str$key: ["
        print_list_ value ui --indentation=nested_indentation
        ui.print "$indentation_str]"
      else:
        ui.print "$indentation_str$key: $value"

  if preferred_keys:
    preferred_keys.do: | key |
      if map.contains key:
        print_key_value.call key map[key]

  keys := map.keys.sort
  keys.do: | key |
    print_key_value.call key map[key]

print_list_ list/List ui/Ui --indentation/int=0:
  indentation_str := " " * indentation
  nested_indentation := indentation + 2
  list.do: | value |
    if value is Map:
      print_map_ value ui --indentation=indentation  --prefix="* "
    else if value is List:
      ui.print "$(indentation_str)* ["
      print_list_ value ui --indentation=nested_indentation
      ui.print "$(indentation_str)]"
    else:
      ui.print "$indentation_str* $value"

print_modification_ modification/Modification --to/Map ui/Ui:
  modification.on_value "firmware"
      --added=: ui.print   "  +firmware: $(prettify_firmware it)"
      --removed=: ui.print "  -firmware"
      --updated=: | _ to | ui.print "  firmware -> $(prettify_firmware to)"

  modification.on_value "max-offline"
      --added=: ui.print   "  +max-offline: $it"
      --removed=: ui.print "  -max-offline"
      --updated=: | _ to | ui.print "  max-offline -> $to"

  has_app_changes := false
  modification.on_value "apps"
      --added=: has_app_changes = true
      --removed=: has_app_changes = true
      --updated=: has_app_changes = true

  if has_app_changes:
    ui.print "  apps:"
    modification.on_map "apps"
        --added=: | name description |
          ui.print "    +$name ($description)"
        --removed=: | name _ |
          ui.print "    -$name"
        --updated=: | name from to |
          print_app_update_ name from to ui

  already_handled := { "firmware", "max-offline", "apps" }
  modification.on_map
      --added=: | name new_value |
        if already_handled.contains name: continue.on_map
        if is_sensitive_ name and new_value is string:
          new_value = "***"
        ui.print "  +$name: $new_value"
      --removed=: | name _ |
        if already_handled.contains name: continue.on_map
        ui.print "  -$name"
      --updated=: | name _ new_value |
        if already_handled.contains name: continue.on_map
        if is_sensitive_ name and new_value is string:
          new_value = "***"
        new_value = filter_sensitive_ new_value
        ui.print "  $name -> $new_value"
      --modified=: | name _ |
        if already_handled.contains name: continue.on_map
        new_value := to[name]
        if is_sensitive_ name and new_value is string:
          new_value = "***"
        ui.print "  $name changed to $new_value"

print_app_update_ name/string from/Map to/Map ui/Ui:
  ui.print "    $name:"
  modification := Modification.compute --from=from --to=to
  modification.on_map
      --added=: | key value |
        ui.print "      +$key: $value"
      --removed=: | key _ |
        ui.print "      -$key"
      --updated=: | key from to |
        ui.print "      $key -> $to"

prettify_firmware firmware/string -> string:
  if firmware.size <= 80: return firmware
  return firmware[0..40] + "..." + firmware[firmware.size - 40..]
