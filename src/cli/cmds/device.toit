// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import encoding.base64
import uuid

import .broker_options_
import .device_container
import ..artemis
import ..cache
import ..config
import ..device_specification
import ..device
import ..event
import ..firmware
import ..organization
import ..sdk
import ..server_config
import ..ui
import ..utils
import ...service.run.host show run_host
import ...shared.json_diff show Modification

create_device_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "device"
      --short_help="Manage devices."

  flash_cmd := cli.Command "flash"
      --long_help="""
        Flashes a device with the Artemis firmware.

        If no identity-file is provided, registers a new device as part
        of the organization-id in the Artemis cloud first.

        If a new device is registered, but no organization-id is provided,
        the device is registered with the default organization.

        The specification file contains the device specification. It includes
        the firmware version, installed applications, connection settings,
        etc. See 'specification-format' for more information.

        If an identity file is provided, the device may also be flashed with
        a firmware image instead of using a specification. In that case, the
        Artemis tool will not connect to the Internet.

        Unless '--no-default' is used, automatically makes this device the
        new default device.
        """
      --options=broker_options + [
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the device.",
        cli.Option "firmware"
            --type="file"
            --short_help="The firmware image to flash.",
        cli.Option "identity"
            --type="file"
            --short_name="i"
            --short_help="The identity file to use.",
        cli.Option "organization-id"
            --type="uuid"
            --short_help="The organization to use.",
        cli.Flag "default"
            --default=true
            --short_help="Make this device the default device.",
        cli.Option "port"
            --short_name="p"
            --required,
        cli.Option "baud",
        cli.Flag "simulate"
            --hidden
            --default=false,
      ]
      --run=:: flash it config cache ui
  cmd.add flash_cmd

  update_cmd := cli.Command "update"
      --long_help="""
        Updates the firmware on the device.

        The specification file contains the device specification. It includes
        the firmware version, installed applications, connection settings,
        etc. See 'specification-format' for more information.
        """
      --options=broker_options + [
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the device."
            --required,
        cli.Option "device-id"
            --short_name="d"
            --short_help="ID of the device."
            --type="uuid",
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
        cli.Option "device-id"
            --short_name="d"
            --short_help="ID of the device."
            --type="uuid",
      ]
      --run=:: default_device it config cache ui
  cmd.add default_cmd

  show_cmd := cli.Command "show"
      --aliases=["status"]
      --long_help="""
        Show all available information about a device.

        If no ID is given, shows the information of the default device.
        """
      --options=broker_options + [
        cli.Option "device-id"
            --short_name="d"
            --short_help="ID of the device."
            --type="uuid",
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
      --options=broker_options + [
        cli.Option "device-id"
            --short_name="d"
            --short_help="ID of the device."
            --type="uuid",
      ]
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

  specification_format_cmd := cli.Command "specification-format"
      --short_help="Show the format of the device specification file."
      --run=:: ui.info SPECIFICATION_FORMAT_HELP
  cmd.add specification_format_cmd

  cmd.add (create_container_command config cache ui)
  return [cmd]

flash parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  organization_id := parsed["organization-id"]
  specification_path := parsed["specification"]
  identity_path := parsed["identity"]
  firmware_path := parsed["firmware"]
  port := parsed["port"]
  baud := parsed["baud"]
  simulate := parsed["simulate"]
  should_make_default := parsed["default"]

  if identity_path and organization_id:
    ui.error "Cannot specify both an identity file and an organization ID."
    ui.abort

  if firmware_path and not identity_path:
    ui.error "Cannot specify a firmware image without an identity file."
    ui.abort

  if firmware_path and specification_path:
    ui.error "Cannot specify both a firmware image and a specification file."
    ui.abort

  device_id/string := ?
  if identity_path:
    identity := read_base64_ubjson identity_path
    // TODO(florian): Abstract away the identity format.
    organization_id = identity["artemis.device"]["organization_id"]
    device_id = identity["artemis.device"]["device_id"]
  else:
    device_id = random_uuid_string

    if not organization_id:
      organization_id = config.get CONFIG_ORGANIZATION_DEFAULT
      if not organization_id:
        ui.error "No organization ID specified and no default organization ID set."
        ui.abort

  with_artemis parsed config cache ui: | artemis/Artemis |
    if not (identity_path and firmware_path):
      // Don't check for the existence of the organization if we are
      // flashing an image together with an identity. We might be
      // on a disconnected flash station.
      org := artemis.connected_artemis_server.get_organization organization_id
      if not org:
        ui.error "Organization $organization_id does not exist."
        ui.abort

    with_tmp_directory: | tmp_dir/string |
      if not identity_path:
        // Provision.
        identity_path = "$tmp_dir/$(device_id).identity"
        artemis.provision
            --device_id=device_id
            --out_path=identity_path
            --organization_id=organization_id
        ui.info "Successfully provisioned device $device_id."

      envelope_path/string := ?

      if specification_path:
        // Customize.
        specification := parse_device_specification_file specification_path --ui=ui
        envelope_path = "$tmp_dir/$(device_id).envelope"
        artemis.customize_envelope
            --output_path=envelope_path
            --device_specification=specification
        artemis.upload_firmware envelope_path --organization_id=organization_id
      else:
        envelope_path = firmware_path

      // Make unique for the given device.
      config_bytes := artemis.compute_device_specific_data
          --envelope_path=envelope_path
          --identity_path=identity_path

      config_path := "$tmp_dir/$(device_id).config"
      write_blob_to_file config_path config_bytes

      sdk_version := Sdk.get_sdk_version_from --envelope=envelope_path
      sdk := get_sdk sdk_version --cache=cache
      if not simulate:
        // Flash.
        sdk.flash
            --envelope_path=envelope_path
            --config_path=config_path
            --port=port
            --baud_rate=baud
        if should_make_default: make_default_ device_id config ui
      else:
        ui.info "Simulating flash."
        ui.info "Using the local Artemis service and not the one specified in the specification."
        old_default := config.get CONFIG_ARTEMIS_DEFAULT_KEY
        identity := read_base64_ubjson identity_path
        if should_make_default: make_default_ device_id config ui
        run_host
            --envelope_path=envelope_path
            --identity_path=identity_path
            --cache=cache
            --ui=ui

update parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device_id := parsed["device-id"]
  specification_path := parsed["specification"]

  if not device_id: device_id = config.get CONFIG_DEVICE_DEFAULT_KEY
  if not device_id:
    ui.error "No device ID specified and no default device ID set."
    ui.abort

  specification := parse_device_specification_file specification_path --ui=ui
  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.update --device_id=device_id --device_specification=specification

default_device parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  if parsed["clear"]:
    config.remove CONFIG_DEVICE_DEFAULT_KEY
    config.write
    ui.info "Default device cleared."
    return

  device_id := parsed["device-id"]
  if not device_id:
    device_id = config.get CONFIG_DEVICE_DEFAULT_KEY
    if not device_id:
      ui.error "No default device set."
      ui.abort

    ui.info "$device_id"
    return

  // TODO(florian): make sure the device exists.
  make_default_ device_id config ui

make_default_ device_id/string config/Config ui/Ui:
  config[CONFIG_DEVICE_DEFAULT_KEY] = device_id
  config.write
  ui.info "Default device set to $device_id"

show parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device_id := parsed["device-id"]
  event_types := parsed["event-type"]
  show_event_values := parsed["show-event-values"]
  max_events := parsed["max-events"]

  if not device_id: device_id = config.get CONFIG_DEVICE_DEFAULT_KEY
  if not device_id:
    ui.error "No device ID specified and no default device ID set."
    ui.abort

  if max_events < 0:
    ui.error "max-events must be >= 0."
    ui.abort

  with_artemis parsed config cache ui: | artemis/Artemis |
    broker := artemis.connected_broker
    artemis_server := artemis.connected_artemis_server
    device := broker.get_device --device_id=device_id
    if not device:
      ui.error "Device $device_id does not exist."
      ui.abort
    organization := artemis_server.get_organization device.organization_id
    events/List? := null
    if max_events != 0:
      events_map := broker.get_events
                        --device_ids=[device_id]
                        --types=event_types.is_empty ? null : event_types
                        --limit=max_events

      events = events_map.get device_id
    ui.info_structured
        --json=: device_to_json_ device organization events
        --stdout=:
          print_device_
              --show_event_values=show_event_values
              device
              organization
              events
              it

set_max_offline parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  max_offline := parsed["max-offline"]
  device_id := get_device_id parsed config ui

  max_offline_seconds := int.parse max_offline --on_error=:
    // Assume it's a duration with units, like "5s".
    duration := parse_duration max_offline --on_error=:
      ui.error "Invalid max-offline duration: $max_offline."
      ui.abort
    duration.in_s

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.config_set_max_offline --device_id=device_id
        --max_offline_seconds=max_offline_seconds
    ui.info "Request sent to broker. Max offline time will be changed when device synchronizes."

device_to_json_
    device/DeviceDetailed
    organization/OrganizationDetailed
    events/List?:
  result := {
    "id": device.id,
    "organization_id": device.organization_id,
    "organization_name": organization.name,
    "goal": device.goal,
    "reported_state_goal": device.reported_state_goal,
    "reported_state_current": device.reported_state_current,
    "reported_state_firmware": device.reported_state_firmware,
  }
  if events:
    result["events"] = events.map: | event/Event | event.to_json
  return result

print_device_
    --show_event_values/bool
    device/DeviceDetailed
    organization/OrganizationDetailed
    events/List?
    ui/Ui:
  ui.print "Device ID: $device.id"
  ui.print "Organization ID: $device.organization_id ($organization.name)"

  if device.reported_state_firmware:
    ui.print ""
    ui.print "Firmware state as reported by the device:"
    prettified := device.reported_state_firmware.map: | key value |
      if key == "firmware": prettify_firmware value
      else: value
    print_map_ prettified ui --indentation=2

  if device.pending_firmware:
    ui.print ""
    ui.print "Firmware installed but not running (pending a reboot):"
    ui.print "   $(prettify_firmware device.pending_firmware)"

  if device.reported_state_current:
    modification := Modification.compute
        --from=device.reported_state_firmware
        --to=device.reported_state_current
    if modification:
      ui.print ""
      ui.print "Current state modifications as reported by the device:"
      print_modification_ modification --to=device.reported_state_current ui

  if device.reported_state_goal:
    diff_to := device.reported_state_current or device.reported_state_firmware
    modification := Modification.compute
        --from=diff_to
        --to=device.reported_state_goal
    ui.print ""
    ui.print "Goal state modifications compared to the current state as reported by the device:"
    print_modification_ modification --to=device.reported_state_goal ui

  if device.goal:
    if not device.reported_state_firmware:
      // Hasn't checked in yet.
      ui.print ""
      ui.print "Goal state:"
      prettified := device.goal.map: | key value |
        if key == "firmware": prettify_firmware value
        else: value
      print_map_ prettified ui --indentation=2
    else:
      diff_to/Map := ?
      diff_to_string/string := ?

      if device.reported_state_goal:
        diff_to = device.reported_state_goal
        diff_to_string = "reported goal state"
      else if device.reported_state_current:
        diff_to = device.reported_state_current
        diff_to_string = "reported current state"
      else:
        diff_to = device.reported_state_firmware
        diff_to_string = "reported firmware state"

      modification := Modification.compute
          --from=diff_to
          --to=device.goal
      if modification == null:
        ui.print ""
        ui.print "Goal is the same as the $diff_to_string."
      else:
        ui.print ""
        ui.print "Goal modifications compared to the $diff_to_string:"
        print_modification_ modification --to=device.goal ui

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

print_map_ map/Map ui/Ui --indentation/int=0:
  indentation_str := " " * indentation
  map.do: | key/string value |
    if value is Map:
      ui.print "$indentation_str$key:"
      print_map_ value ui --indentation=indentation + 2
    else:
      ui.print "$indentation_str$key: $value"

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
        --added=: | name id |
          ui.print "    +$name ($id)"
        --removed=: | name id |
          ui.print "    -$name"
        --updated=: | name id |
          ui.print "    $name -> $id"

  already_handled := { "firmware", "max-offline", "apps" }
  modification.on_map
      --added=: | name new_value |
        if already_handled.contains name: continue.on_map
        ui.print "  +$name: $new_value"
      --removed=: | name _ |
        if already_handled.contains name: continue.on_map
        ui.print "  -$name"
      --updated=: | name _ new_value |
        if already_handled.contains name: continue.on_map
        ui.print "  $name -> $new_value"
      --modified=: | name _ |
        if already_handled.contains name: continue.on_map
        ui.print "  $name changed to $to[name]"

prettify_firmware firmware/string -> string:
  if firmware.size <= 80: return firmware
  return firmware[0..40] + "..." + firmware[firmware.size - 40..]

SPECIFICATION_FORMAT_HELP ::= """
  The format of the device specification file.

  The specification file is a JSON file with the following entries:

  'version': The version of the specification file. Must be '1'.
  'sdk': The SDK version to use. This is a string of the form
      'major.minor.patch', e.g. '1.2.3'.
  'artemis': The Artemis service version to use. This is a string of the
      form 'major.minor.patch', e.g. '1.2.3'.
  'max_offline': The duration the device can be offline before it
      attempts to connect to the broker to sync. Expressed as
      string of the form '1h2m3s' or '1h 2m 3s'.
  'connections': a list of connections, each of which must be a
      connection object. See below for the format of a connection object.
  'apps': a list of applications, each of which must be an application
      object. See below for the format of an application object.


  A connection object consists of the following entries:
  'type': The type of the connection. Must be 'wifi'.

  For 'wifi' connections:
  'ssid': The SSID of the network to connect to.
  'password': The password of the network to connect to.


  Applications entries are compiled to containers that are installed in
  the firmware.
  They always have a 'name' entry which is the name of the container.

  Snapshot applications have a 'snapshot' entry which must be a path to the
  snapshot file.

  Source applications have an 'entrypoint' entry which must be a path to the
  entrypoint file.
  Source applications may also have a 'git' and 'branch' entry (which can be a
  branch or tag) to checkout a git repository first.
  """
