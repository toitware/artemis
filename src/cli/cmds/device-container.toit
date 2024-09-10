// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show *
import uuid

import .device
import .utils_
import ..artemis
import ..cache
import ..config
import ..fleet
import ..pod-specification as pod-specification
import ..utils

create-container-command -> Command:
  cmd := Command "container"
      --help="Manage the containers installed on a device."

  install-cmd := Command "install"
      --help="Install a container on a device."
      --options=[
        OptionPatterns "trigger"
            ["none", "boot", "install", "interval:<duration>", "gpio-high:<pin>", "gpio-low:<pin>"]
            --help="Trigger to start the container. Defaults to 'boot,install'."
            --split-commas
            --multi,
        Flag "background"
            --help="Run in background and do not delay sleep."
            --default=false,
        Flag "critical"
            --help="Run automatically and restart if necessary."
            --default=false,
      ]
      --rest=[
        OptionString "name"
            --help="Name of the container when installed."
            --required,
        OptionString "path"
            --help="Path to source code or snapshot."
            --type="file"
            --required,
        Option "arguments"
            --help="Argument to pass to the container."
            --type="string"
            --multi,
      ]
      --examples=[
        Example "Install the 'hello' container and run it every 5 seconds:"
            --arguments="--trigger=interval:5s hello hello.toit",
      ]
      --run=:: install-container it
  cmd.add install-cmd

  uninstall-cmd := Command "uninstall"
      --help="Uninstall a container from a device."
      --options=[
          Flag "force"
            --short-name="f"
            --help="Force uninstallation of a container that is required for a connection."
            --default=false,
      ]
      --rest=[
        OptionString "name"
            --help="Name of the container to uninstall.",
      ]
      --run=:: uninstall-container it
  cmd.add uninstall-cmd

  return cmd

install-container invocation/Invocation:
  params := invocation.parameters
  ui := invocation.cli.ui

  container-name := params["name"]
  container-path := params["path"]
  arguments := params["arguments"]
  is-critical := params["critical"]
  parsed-triggers := params["trigger"]

  if is-critical and not parsed-triggers.is-empty:
    ui.abort "Critical containers cannot have triggers."

  seen-triggers := {}
  seen-pins := {}
  triggers := []
  parsed-triggers.do: | parsed-trigger |
    if parsed-trigger is string:
      if seen-triggers.contains parsed-trigger:
        ui.abort "Duplicate trigger '$parsed-trigger'."
      seen-triggers.add parsed-trigger

    if parsed-trigger == "none":
      // Do nothing. We check that parsed_trigger's the only trigger later.
    else if parsed-trigger == "boot":
      triggers.add pod-specification.BootTrigger
    else if parsed-trigger == "install":
      triggers.add pod-specification.InstallTrigger
    else if parsed-trigger is Map and parsed-trigger.contains "interval":
      if seen-triggers.contains "interval":
        ui.abort "Duplicate trigger 'interval'."
      seen-triggers.add "interval"
      duration := parse-duration parsed-trigger["interval"] --on-error=:
        ui.abort "Invalid interval '$parsed-trigger'. Use 20s, 5m10s, 12h or similar."
      triggers.add (pod-specification.IntervalTrigger duration)
    else if parsed-trigger is Map and (parsed-trigger.contains "gpio-low" or parsed-trigger.contains "gpio-high"):
      // Add an entry to the seen triggers list, so we can ensure that it's not combined with 'none'.
      seen-triggers.add "gpio"
      on-high := parsed-trigger.contains "gpio-high"
      pin-string := on-high ? parsed-trigger["gpio-high"] : parsed-trigger["gpio-low"]
      pin := int.parse pin-string --on-error=:
        ui.abort "Invalid pin '$pin-string'."

      if seen-pins.contains pin:
        ui.abort "Duplicate trigger for pin '$pin'."
      seen-pins.add pin

      triggers.add (on-high
          ? pod-specification.GpioTriggerHigh pin
          : pod-specification.GpioTriggerLow pin)
    else:
      ui.abort "Invalid trigger '$parsed-trigger'."
      unreachable

  if seen-triggers.contains "none":
    if seen-triggers.size != 1:
      ui.abort "Trigger 'none' cannot be combined with other triggers."
    triggers = []
  else if not is-critical and triggers.is-empty:
    // Non-critical containers get a boot and an install trigger by default.
    triggers = [pod-specification.BootTrigger, pod-specification.InstallTrigger]

  with-device invocation: | device/DeviceFleet fleet/FleetWithDevices |
    fleet.broker.container-install
        --device-id=device.id
        --app-name=container-name
        --arguments=arguments
        --background=invocation["background"]
        --critical=is-critical
        --triggers=triggers
        --application-path=container-path
    ui.inform "Request sent to broker. Container will be installed when device synchronizes."

uninstall-container invocation/Invocation:
  container-name := invocation["name"]
  force := invocation["force"]

  with-device invocation: | device/DeviceFleet fleet/FleetWithDevices |
    fleet.broker.container-uninstall --device-id=device.id --app-name=container-name --force=force
    invocation.cli.ui.inform "Request sent to broker. Container will be uninstalled when device synchronizes."
