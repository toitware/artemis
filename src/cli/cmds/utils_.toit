// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show *
import host.os
import uuid

import ..artemis
import ..config
import ..cache
import ..fleet
import ..server-config
import ..utils

with-artemis invocation/Invocation [block]:
  cli := invocation.cli
  artemis-config := get-server-from-config --cli=cli --key=CONFIG-ARTEMIS-DEFAULT-KEY

  with-tmp-directory: | tmp-directory/string |
    artemis := Artemis
        --cli=invocation.cli
        --tmp-directory=tmp-directory
        --server-config=artemis-config
    try:
      block.call artemis
    finally:
      artemis.close

default-device-from-config --cli/Cli -> uuid.Uuid?:
  config := cli.config
  device-id-string := config.get CONFIG-DEVICE-DEFAULT-KEY
  if not device-id-string: return null
  return uuid.parse device-id-string

default-organization-from-config --cli/Cli -> uuid.Uuid?:
  config := cli.config
  organization-id-string := config.get CONFIG-ORGANIZATION-DEFAULT-KEY
  if not organization-id-string: return null
  return uuid.parse organization-id-string

with-devices-fleet invocation/Invocation [block]:
  cli := invocation.cli

  // If the result of the compute-call isn't a root, but a reference, then
  // the constructor call below will throw.
  fleet-root := compute-fleet-root-or-ref invocation

  with-artemis invocation: | artemis/Artemis |
    default-broker-config := get-server-from-config --cli=cli --key=CONFIG-BROKER-DEFAULT-KEY
    fleet := FleetWithDevices fleet-root artemis
        --default-broker-config=default-broker-config
        --cli=cli
    block.call fleet

with-pod-fleet invocation/Invocation [block]:
  cli := invocation.cli

  fleet-root-or-ref := compute-fleet-root-or-ref invocation

  with-artemis invocation: | artemis/Artemis |
    default-broker-config := get-server-from-config --cli=cli --key=CONFIG-BROKER-DEFAULT-KEY
    fleet := Fleet fleet-root-or-ref artemis
        --default-broker-config=default-broker-config
        --cli=cli
    block.call fleet

compute-fleet-root-or-ref invocation -> string:
  ui := invocation.cli.ui
  fleet-root := invocation["fleet-root"]  // Old deprecated argument.
  fleet-root-or-ref := invocation["fleet"]
  if fleet-root and fleet-root-or-ref:
    ui.abort "The arguments --fleet-root and --fleet are mutually exclusive."
  fleet-root-or-ref = fleet-root-or-ref or fleet-root
  if fleet-root-or-ref: return fleet-root-or-ref
  // For the environment 'ARTEMIS_FLEET' wins.
  fleet-env := os.env.get "ARTEMIS_FLEET" or os.env.get "ARTEMIS_FLEET_ROOT"
  if fleet-env:
    ui.debug "Using fleet-root '$fleet-env' provided by environment variable."
    return fleet-env
  return "."

make-default_ --device-id/uuid.Uuid --cli/Cli:
  cli.config[CONFIG-DEVICE-DEFAULT-KEY] = "$device-id"
  cli.config.write
  cli.ui.inform "Default device set to $device-id."
