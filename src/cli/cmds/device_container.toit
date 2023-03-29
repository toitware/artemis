// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli

import .broker_options_
import ..artemis
import ..cache
import ..config
import ..device_specification as device_specification
import ..ui
import ..utils

create_container_command config/Config cache/Cache ui/Ui -> cli.Command:
  cmd := cli.Command "container"
      --short_help="Manage the containers installed on a device."
      --options=broker_options + [
        cli.Option "device-id"
            --short_name="d"
            --short_help="ID of the device."
            --type="uuid",
      ]

  install_cmd := cli.Command "install"
      --short_help="Install a container on a device."
      --options=[
        OptionPatterns "trigger"
            ["none", "boot", "install", "interval:<duration>", "gpio-high:<pin>", "gpio-low:<pin>"]
            --short_help="Trigger to start the container. Defaults to 'boot,install'."
            --split_commas
            --multi,
        cli.Flag "background"
            --short_help="Run in background and do not delay sleep."
            --default=false,
        cli.Flag "critical"
            --short_help="Run automatically and restart if necessary."
            --default=false,
      ]
      --rest=[
        cli.OptionString "name"
            --short_help="Name of the container when installed."
            --required,
        cli.OptionString "path"
            --short_help="Path to source code or snapshot."
            --type="file"
            --required,
        cli.Option "arguments"
            --short_help="Argument to pass to the container."
            --type="string"
            --multi,
      ]
      --run=:: install_container it config cache ui
  cmd.add install_cmd

  uninstall_cmd := cli.Command "uninstall"
      --long_help="Uninstall a container from a device."
      --rest=[
        cli.OptionString "name"
            --short_help="Name of the container to uninstall.",
      ]
      --run=:: uninstall_container it config cache ui
  cmd.add uninstall_cmd

  return cmd

get_device_id parsed/cli.Parsed config/Config ui/Ui -> string:
  device_id := parsed["device-id"]
  if not device_id: device_id = config.get CONFIG_DEVICE_DEFAULT_KEY
  if not device_id:
    ui.error "No device ID specified and no default device ID set."
    ui.abort
  return device_id

install_container parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  container_name := parsed["name"]
  container_path := parsed["path"]
  arguments := parsed["arguments"]
  is_critical := parsed["critical"]
  parsed_triggers := parsed["trigger"]
  device_id := get_device_id parsed config ui

  if is_critical and not parsed_triggers.is_empty:
    ui.error "Critical containers cannot have triggers."
    ui.abort

  seen_triggers := {}
  seen_pins := {}
  triggers := []
  parsed_triggers.do: | parsed_trigger |
    if parsed_trigger is string:
      if seen_triggers.contains parsed_trigger:
        ui.error "Duplicate trigger '$parsed_trigger'."
        ui.abort
      seen_triggers.add parsed_trigger

    if parsed_trigger == "none":
      // Do nothing. We check that parsed_trigger's the only trigger later.
    else if parsed_trigger == "boot":
      triggers.add device_specification.BootTrigger
    else if parsed_trigger == "install":
      triggers.add device_specification.InstallTrigger
    else if parsed_trigger is Map and parsed_trigger.contains "interval":
      if seen_triggers.contains "interval":
        ui.error "Duplicate trigger 'interval'."
        ui.abort
      seen_triggers.add "interval"
      duration := parse_duration parsed_trigger["interval"] --on_error=:
        ui.error "Invalid interval '$parsed_trigger'. Use 20s, 5m10s, 12h or similar."
        ui.abort
      triggers.add (device_specification.IntervalTrigger duration)
    else if parsed_trigger is Map and (parsed_trigger.contains "gpio-low" or parsed_trigger.contains "gpio-high"):
      // Add an entry to the seen triggers list, so we can ensure that it's not combined with 'none'.
      seen_triggers.add "gpio"
      on_high := parsed_trigger.contains "gpio-high"
      pin_string := on_high ? parsed_trigger["gpio-high"] : parsed_trigger["gpio-low"]
      pin := int.parse pin_string --on_error=:
        ui.error "Invalid pin '$pin_string'."
        ui.abort

      if seen_pins.contains pin:
        ui.error "Duplicate trigger for pin '$pin'."
        ui.abort
      seen_pins.add pin

      triggers.add (on_high
          ? device_specification.GpioTriggerHigh pin
          : device_specification.GpioTriggerLow pin)
    else:
      ui.error "Invalid trigger '$parsed_trigger'."
      ui.abort
      unreachable

  if seen_triggers.contains "none":
    if seen_triggers.size != 1:
      ui.error "Trigger 'none' cannot be combined with other triggers."
      ui.abort
    triggers = []
  else if triggers.is_empty:
    triggers = [device_specification.BootTrigger, device_specification.InstallTrigger]

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.container_install
        --device_id=device_id
        --app_name=container_name
        --arguments=arguments
        --background=parsed["background"]
        --critical=is_critical
        --triggers=triggers
        --application_path=container_path
    ui.info "Request sent to broker. Container will be installed when device synchronizes."

uninstall_container parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  container_name := parsed["name"]
  device_id := get_device_id parsed config ui

  with_artemis parsed config cache ui: | artemis/Artemis |
    artemis.container_uninstall --device_id=device_id --app_name=container_name
    ui.info "Request sent to broker. Container will be uninstalled when device synchronizes."

class OptionPatterns extends cli.OptionEnum:
  constructor name/string patterns/List
      --default=null
      --short_name/string?=null
      --short_help/string?=null
      --required/bool=false
      --hidden/bool=false
      --multi/bool=false
      --split_commas/bool=false:
    super name patterns
      --default=default
      --short_name=short_name
      --short_help=short_help
      --required=required
      --hidden=hidden
      --multi=multi
      --split_commas=split_commas

  parse str/string --for_help_example/bool=false -> any:
    if not str.contains ":" and not str.contains "=":
      // Make sure it's a valid one.
      key := super str --for_help_example=for_help_example
      return key

    separator_index := str.index_of ":"
    if separator_index < 0: separator_index = str.index_of "="
    key := str[..separator_index]
    key_with_equals := str[..separator_index + 1]
    if not (values.any: it.starts_with key_with_equals):
      throw "Invalid value for option '$name': '$str'. Valid values are: $(values.join ", ")."

    return {
      key: str[separator_index + 1..]
    }
