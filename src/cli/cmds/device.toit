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
import ..firmware
import ..sdk
import ..server_config
import ..ui
import ..utils
import ...service.run.host show run_host

create_device_commands config/Config cache/Cache ui/Ui -> List:
  cmd := cli.Command "device"
      --short_help="Manage devices."

  provision_cmd := cli.Command "provision"
      --long_help="""
        Provision a new device.

        Registers a new device with the Toit cloud and writes the identity file
        to the specified directory/file. The identity file is used
        during flashing and allows the device to connect to the Toit cloud.

        If a device-id is specified, the device is registered with that
        ID. Otherwise, a new ID is generated.

        If an organization-id is specified, the device is registered with
        that organization. Otherwise, the device is registered with the
        default organization.

        The options '--output-directory' and '--output' are mutually exclusive.
        """
      --options= broker_options + [
        cli.Option "device-id"
            --type="uuid"
            --short_name="d"
            --short_help="The device ID to use.",
        cli.Option "output-directory"
            --type="directory"
            --short_help="Directory to write the identity file to.",
        cli.Option "output"
            --type="out-file"
            --short_name="o"
            --short_help="File to write the identity to.",
        cli.Option "organization-id"
            --type="uuid"
            --short_help="The organization to use."
      ]
      --run=:: provision it config cache ui
  cmd.add provision_cmd

  flash_cmd := cli.Command "flash"
      --long_help="""
        Registers a new device with the Toit cloud and flashes the Artemis
        firmware on the device.

        If a device-id is specified, the device is registered with that
        ID. Otherwise, a new ID is generated.

        If an organization-id is specified, the device is registered with
        that organization. Otherwise, the device is registered with the
        default organization.

        The specification file contains the device specification. It includes
        the firmware version, installed applications, connection settings,
        etc. See 'specification-format' for more information.

        Unless '--no-default' is used, automatically makes this device the
        new default device.
        """
      --options=broker_options + [
        cli.Option "specification"
            --type="file"
            --short_help="The specification of the device."
            --required,
        cli.Option "device-id"
            --type="uuid"
            --short_name="d"
            --short_help="The device ID to use.",
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

  configuration_cmd := cli.Command "configuration"
      --long_help="""
        Show the configuration of the device.

        If no ID is given, shows the configuration of the default device.

        If the device's current configuration is different from the goal
        configuration, both configurations are shown. Use '--goal' or
        '--current' to only show one of them.

        The configuration is distilled from the specification. In a
        configuration the applications are compiled and their checksums
        are known.
        """
      --options=[
        cli.Option "device-id"
            --short_name="d"
            --short_help="ID of the device."
            --type="uuid",
        cli.Flag "goal"
            --short_help="Show the goal configuration.",
        cli.Flag "current"
            --short_help="Show the current configuration.",
      ]
      --run=:: configuration it config cache ui
  cmd.add configuration_cmd

  specification_format_cmd := cli.Command "specification-format"
      --short_help="Prints the format of the device specification file."
      --run=:: ui.info SPECIFICATION_FORMAT_HELP
  cmd.add specification_format_cmd

  cmd.add (create_transient_command config cache ui)
  return [cmd]

with_artemis parsed/cli.Parsed config/Config cache/Cache ui/Ui [block]:
  broker_config := get_server_from_config config parsed["broker"] CONFIG_BROKER_DEFAULT_KEY
  artemis_config := get_server_from_config config parsed["broker.artemis"] CONFIG_ARTEMIS_DEFAULT_KEY

  artemis := Artemis --config=config --cache=cache --ui=ui \
      --broker_config=broker_config --artemis_config=artemis_config

  try:
    block.call artemis
  finally:
    artemis.close

provision parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device_id := parsed["device-id"]
  output_directory := parsed["output-directory"]
  output := parsed["output"]
  organization_id := parsed["organization-id"]

  if not device_id:
    device_id = (uuid.uuid5 "Device ID" "$Time.now $random").stringify

  if output_directory and output:
    ui.error "The options '--output-directory' and '--output' are mutually exclusive."
    ui.abort

  if not output_directory and not output:
    output_directory = "."
  if not output:
    output = "$output_directory/$(device_id).identity"

  if not organization_id:
    organization_id = config.get CONFIG_ORGANIZATION_DEFAULT
    if not organization_id:
      ui.error "No organization ID specified and no default organization ID set."
      ui.abort

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.provision
        --device_id=device_id
        --out_path=output
        --organization_id=organization_id
    ui.info "Successfully provisioned device $device_id."
    ui.info "Created $output."

flash parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  device_id := parsed["device-id"]
  organization_id := parsed["organization-id"]
  specification_path := parsed["specification"]
  port := parsed["port"]
  baud := parsed["baud"]
  simulate := parsed["simulate"]
  should_make_default := parsed["default"]

  if not device_id:
    device_id = (uuid.uuid5 "Device ID" "$Time.now $random").stringify

  if not organization_id:
    organization_id = config.get CONFIG_ORGANIZATION_DEFAULT
    if not organization_id:
      ui.error "No organization ID specified and no default organization ID set."
      ui.abort

  with_artemis parsed config cache ui: | artemis/Artemis |
    with_tmp_directory: | tmp_dir/string |
      // Provision.
      identity_file := "$tmp_dir/$(device_id).identity"
      artemis.provision
          --device_id=device_id
          --out_path=identity_file
          --organization_id=organization_id
      ui.info "Successfully provisioned device $device_id."

      // Customize.
      specification := DeviceSpecification.parse specification_path
      envelope_path := "$tmp_dir/$(device_id).envelope"
      artemis.customize_envelope
          --organization_id=organization_id
          --output_path=envelope_path
          --device_specification=specification

      // Make unique for the given device.
      config_bytes := artemis.compute_device_specific_data
          --envelope_path=envelope_path
          --identity_path=identity_file

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
        identity := read_base64_ubjson identity_file
        if should_make_default: make_default_ device_id config ui
        run_host
            --envelope_path=envelope_path
            --identity_path=identity_file
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

configuration parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  throw "UNIMPLEMENTED"

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
