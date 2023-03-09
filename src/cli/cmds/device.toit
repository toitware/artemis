// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import encoding.base64
import uuid

import .broker_options_
import .device_transient
import ..artemis
import ..cache
import ..config
import ..device_specification
import ..device
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
        a firmware image instead of using a specification.

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
            --type="uuid"
            --short_name="d"
            --short_help="The ID of the device.",
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
      ]
      --run=:: default_device it config cache ui
  cmd.add default_cmd

  show_cmd := cli.Command "show"
      --long_help="""
        Show all available information about a device.

        If no ID is given, shows the information of the default device.
        """
      --options= broker_options + [
        cli.Option "device-id"
            --short_name="d"
            --short_help="ID of the device."
            --type="uuid",
      ]
      --run=:: show it config cache ui
  cmd.add show_cmd

  specification_format_cmd := cli.Command "specification-format"
      --short_help="Prints the format of the device specification file."
      --run=:: ui.info SPECIFICATION_FORMAT_HELP
  cmd.add specification_format_cmd

  cmd.add (create_transient_command config cache ui)
  return [cmd]

flash parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  organization_id := parsed["organization-id"]
  specification_path := parsed["specification"]
  identity_path := parsed["identity"]
  port := parsed["port"]
  baud := parsed["baud"]
  simulate := parsed["simulate"]
  should_make_default := parsed["default"]

  if identity_path and organization_id:
    ui.error "Cannot specify both an identity file and an organization ID."
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

      // Customize.
      specification := DeviceSpecification.parse specification_path
      envelope_path := "$tmp_dir/$(device_id).envelope"
      artemis.customize_envelope
          --output_path=envelope_path
          --device_specification=specification

      artemis.upload_firmware envelope_path --organization_id=organization_id

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

  specification := DeviceSpecification.parse specification_path
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
  if not device_id: device_id = config.get CONFIG_DEVICE_DEFAULT_KEY
  if not device_id:
    ui.error "No device ID specified and no default device ID set."
    ui.abort

  with_artemis parsed config cache ui: | artemis/Artemis |
    broker := artemis.connected_broker
    artemis_server := artemis.connected_artemis_server
    device := broker.get_device --device_id=device_id
    organization := artemis_server.get_organization device.organization_id
    ui.info_structured
        --json=: device_to_json_ device organization
        --stdout=: print_device_ device organization it

device_to_json_ device/DeviceDetailed organization/OrganizationDetailed:
  return {
    "id": device.id,
    "organization_id": device.organization_id,
    "organization_name": organization.name,
    "goal": device.goal,
    "reported_state_goal": device.reported_state_goal,
    "reported_state_current": device.reported_state_current,
    "reported_state_firmware": device.reported_state_firmware,
  }

print_device_ device/DeviceDetailed organization/OrganizationDetailed ui/Ui:
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
