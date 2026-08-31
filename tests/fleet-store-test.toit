// Copyright (C) 2026 Toit contributors. All rights reserved.

import artemis.cli.fleet show
    DEFAULT-GROUP
    DeviceFleet
    Fleet
import artemis.cli.file-fleet-store show FileFleetStoreStrategy
import artemis.cli.fleet-store show FleetStore
import artemis.cli.pod-registry show PodReference
import artemis.cli.server-config show ServerConfigHttp
import artemis.shared.scope show Scope
import expect show *
import host
import uuid show Uuid

import .utils show TestCli

FLEET-ID ::= "00000000-0000-0000-0000-000000000001"
DEVICE-ID ::= "00000000-0000-0000-0000-000000000002"
ORGANIZATION-ID ::= "00000000-0000-0000-0000-000000000003"

class MemoryFleetStore implements FleetStore:
  id/Uuid
  group-pods/Map := ?
  devices/List := ?

  constructor
      --.id
      --.group-pods
      --.devices:

  save-fleet -> none
      --group-pods/Map?=null:
    if group-pods != null: this.group-pods = group-pods

  save-devices devices/List -> none:
    this.devices = devices

main:
  host.with-tmp-directory: | tmp/string |
    cli := TestCli

    memory-store := MemoryFleetStore
        --id=Uuid.parse FLEET-ID
        --group-pods=initial-groups cli
        --devices=initial-devices
    exercise-contract memory-store --cli=cli

    server-config := ServerConfigHttp "test"
        --url="http://localhost"
        --scope=Scope ORGANIZATION-ID

    file-strategy := FileFleetStoreStrategy
        --root=tmp
        --legacy-default-broker-config=server-config
        --cli=cli
    file-store := file-strategy.create
        --id=Uuid.parse FLEET-ID
        --group-pods=initial-groups cli
        --devices=initial-devices
    exercise-contract file-store --cli=cli

    reloaded := file-strategy.open
    expect-final-state reloaded

    reference-path := "$tmp/fleet-reference.json"
    file-store.write-reference --path=reference-path
    reference-strategy := FileFleetStoreStrategy
        --root=reference-path
        --legacy-default-broker-config=server-config
        --cli=cli
    reference := reference-strategy.open-reference
    expect-equals FLEET-ID "$reference.id"
    expect-equals server-config.name reference.broker-name

initial-groups cli/TestCli -> Map:
  return {
    DEFAULT-GROUP: PodReference.parse "initial@latest" --cli=cli,
  }

initial-devices -> List:
  return [
    DeviceFleet
        --id=Uuid.parse DEVICE-ID
        --name="device"
        --group=DEFAULT-GROUP,
  ]

exercise-contract store/FleetStore --cli/TestCli:
  fleet := Fleet store --cli=cli

  staging := PodReference.parse "staging@latest" --cli=cli
  production := PodReference.parse "production@v1" --cli=cli
  fleet.add-group "staging" staging
  expect-equals "staging@latest" "$(store.group-pods["staging"])"

  moved := fleet.move-devices
      --ids={Uuid.parse DEVICE-ID}
      --groups={}
      --to="staging"
  expect-equals 1 moved
  expect-equals "staging" (store.devices.first as DeviceFleet).group

  fleet.rename-group "staging" "production"
  fleet.update-group "production" production
  fleet.add-group "unused" staging
  expect (fleet.remove-group "unused")
  expect-final-state store

expect-final-state store/FleetStore:
  expect (store.group-pods.contains DEFAULT-GROUP)
  expect (store.group-pods.contains "production")
  expect-not (store.group-pods.contains "staging")
  expect-not (store.group-pods.contains "unused")
  expect-equals "production@v1" "$(store.group-pods["production"])"
  expect-equals "production" (store.devices.first as DeviceFleet).group
