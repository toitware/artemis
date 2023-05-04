// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli
import uuid

import .utils_
import ..artemis
import ..cache
import ..config
import ..pod_specification as pod_specification
import ..ui
import ..utils

create_container_command config/Config cache/Cache ui/Ui -> cli.Command:
  cmd := cli.Command "container"
      --short_help="Manage the containers installed on a device."

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

get_device_id parsed/cli.Parsed config/Config ui/Ui -> uuid.Uuid:
  device_id := parsed["device-id"]
  if not device_id:
    device_id = default_device_from_config config
  if not device_id:
    ui.abort "No device ID specified and no default device ID set."
  return device_id

install_container parsed/cli.Parsed config/Config cache/Cache ui/Ui:
  container_name := parsed["name"]
  container_path := parsed["path"]
  arguments := parsed["arguments"]
  is_critical := parsed["critical"]
  parsed_triggers := parsed["trigger"]
  device_id := get_device_id parsed config ui

  if is_critical and not parsed_triggers.is_empty:
    ui.abort "Critical containers cannot have triggers."

  seen_triggers := {}
  seen_pins := {}
  triggers := []
  parsed_triggers.do: | parsed_trigger |
    if parsed_trigger is string:
      if seen_triggers.contains parsed_trigger:
        ui.abort "Duplicate trigger '$parsed_trigger'."
      seen_triggers.add parsed_trigger

    if parsed_trigger == "none":
      // Do nothing. We check that parsed_trigger's the only trigger later.
    else if parsed_trigger == "boot":
      triggers.add pod_specification.BootTrigger
    else if parsed_trigger == "install":
      triggers.add pod_specification.InstallTrigger
    else if parsed_trigger is Map and parsed_trigger.contains "interval":
      if seen_triggers.contains "interval":
        ui.abort "Duplicate trigger 'interval'."
      seen_triggers.add "interval"
      duration := parse_duration parsed_trigger["interval"] --on_error=:
        ui.abort "Invalid interval '$parsed_trigger'. Use 20s, 5m10s, 12h or similar."
      triggers.add (pod_specification.IntervalTrigger duration)
    else if parsed_trigger is Map and (parsed_trigger.contains "gpio-low" or parsed_trigger.contains "gpio-high"):
      // Add an entry to the seen triggers list, so we can ensure that it's not combined with 'none'.
      seen_triggers.add "gpio"
      on_high := parsed_trigger.contains "gpio-high"
      pin_string := on_high ? parsed_trigger["gpio-high"] : parsed_trigger["gpio-low"]
      pin := int.parse pin_string --on_error=:
        ui.abort "Invalid pin '$pin_string'."

      if seen_pins.contains pin:
        ui.abort "Duplicate trigger for pin '$pin'."
      seen_pins.add pin

      triggers.add (on_high
          ? pod_specification.GpioTriggerHigh pin
          : pod_specification.GpioTriggerLow pin)
    else:
      ui.abort "Invalid trigger '$parsed_trigger'."
      unreachable

  if seen_triggers.contains "none":
    if seen_triggers.size != 1:
      ui.abort "Trigger 'none' cannot be combined with other triggers."
    triggers = []
  else if not is_critical and triggers.is_empty:
    // Non-critical containers get a boot and an install trigger by default.
    triggers = [pod_specification.BootTrigger, pod_specification.InstallTrigger]

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
