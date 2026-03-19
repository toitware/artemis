// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show *
import host.os
import partition-table show PartitionTable
import uuid show Uuid

import ..config
import ..cache
import ..fleet
import ..pod
import ..sdk
import ..server-config
import ..utils

default-device-from-config --cli/Cli -> Uuid?:
  config := cli.config
  device-id-string := config.get CONFIG-DEVICE-DEFAULT-KEY
  if not device-id-string: return null
  return Uuid.parse device-id-string

default-organization-from-config --cli/Cli -> Uuid?:
  config := cli.config
  organization-id-string := config.get CONFIG-ORGANIZATION-DEFAULT-KEY
  if not organization-id-string: return null
  return Uuid.parse organization-id-string

with-devices-fleet invocation/Invocation [block]:
  cli := invocation.cli

  // If the result of the compute-call isn't a root, but a reference, then
  // the constructor call below will throw.
  fleet-root := compute-fleet-root-or-ref invocation

  with-tmp-directory: | tmp-directory/string |
    default-broker-config := get-server-from-config --cli=cli --key=CONFIG-BROKER-DEFAULT-KEY
    fleet := FleetWithDevices fleet-root
        --tmp-directory=tmp-directory
        --default-broker-config=default-broker-config
        --cli=cli
    block.call fleet

with-pod-fleet invocation/Invocation [block]:
  cli := invocation.cli

  fleet-root-or-ref := compute-fleet-root-or-ref invocation

  with-tmp-directory: | tmp-directory/string |
    default-broker-config := get-server-from-config --cli=cli --key=CONFIG-BROKER-DEFAULT-KEY
    fleet := Fleet fleet-root-or-ref
        --tmp-directory=tmp-directory
        --default-broker-config=default-broker-config
        --cli=cli
    block.call fleet

compute-fleet-root-or-ref invocation/Invocation -> string:
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
    ui.emit --debug "Using fleet-root '$fleet-env' provided by environment variable."
    return fleet-env
  return "."

make-default_ --device-id/Uuid --cli/Cli:
  cli.config[CONFIG-DEVICE-DEFAULT-KEY] = "$device-id"
  cli.config.write
  cli.ui.emit --info "Default device set to $device-id."

check-esp32-partition-size_ pod/Pod --ui/Ui --force/bool -> none:
  chip := Sdk.get-chip-family-from --envelope=pod.envelope
  partition-table-data := pod.partition-table
  if not partition-table-data:
    partition-table-data = Sdk.get-partition-table-bin-from --envelope=pod.envelope
  table := PartitionTable.decode partition-table-data
  ota-partition := table.find --name="ota_0"
  if not ota-partition:
    ui.abort "No OTA partition ('ota_0') found in the partition table."
  partition-size := ota-partition.size
  if partition-size < 0x1c0000:
    if force:
      ui.emit --warning "The OTA partition is smaller than 1.75 MiB."
      ui.emit --warning "Flashing will continue due to '--force'."
    else:
      ui.emit --error "The OTA partition is smaller than 1.75 MiB."
      ui.emit --error "Use '--force' to flash anyway."
      ui.abort
