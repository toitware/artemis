// Copyright (C) 2026 Toitware ApS. All rights reserved.

import artemis.cli.artemis show Artemis
import artemis.cli.fleet show
    DEFAULT-GROUP
    DeviceFleet
    DevicesFile
    FileFleetStore
    Fleet
    FleetFile
    FleetStore
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

class MemoryFleetStore extends FleetStore:
  id/Uuid
  is-reference/bool
  group-pods/Map := ?
  devices/List := ?
  broker-name/string := ?
  migrating-from/List := ?
  servers/Map := ?
  recovery-urls/List := ?

  constructor
      --.id
      --.group-pods
      --.devices
      --.broker-name
      --.servers
      --.migrating-from=[]
      --.recovery-urls=[]
      --.is-reference=false:

  root -> string?: return null
  has-devices -> bool: return true

  save-fleet -> none
      --group-pods/Map?=null
      --broker-name/string?=null
      --migrating-from/List?=null
      --servers/Map?=null
      --recovery-urls/List?=null:
    if group-pods != null: this.group-pods = group-pods
    if broker-name != null: this.broker-name = broker-name
    if migrating-from != null: this.migrating-from = migrating-from
    if servers != null: this.servers = servers
    if recovery-urls != null: this.recovery-urls = recovery-urls

  save-devices devices/List -> none:
    this.devices = devices

  write-reference --path/string -> none:
    throw "Memory fleet stores cannot write reference files."

main:
  host.with-tmp-directory: | tmp/string |
    cli := TestCli
    server-config := ServerConfigHttp "test"
        --url="http://localhost"
        --scope=(Scope ORGANIZATION-ID)

    memory-store := MemoryFleetStore
        --id=(Uuid.parse FLEET-ID)
        --group-pods=(initial-groups cli)
        --devices=initial-devices
        --broker-name=server-config.name
        --servers={server-config.name: server-config}
    exercise-contract memory-store tmp --server-config=server-config --cli=cli

    fleet-file := FleetFile
        --path="$tmp/$(FileFleetStore.FLEET-FILE)"
        --id=(Uuid.parse FLEET-ID)
        --group-pods=(initial-groups cli)
        --is-reference=false
        --broker-name=server-config.name
        --migrating-from=[]
        --servers={server-config.name: server-config}
        --recovery-urls=[]
    fleet-file.write
    (DevicesFile "$tmp/$(FileFleetStore.DEVICES-FILE)" initial-devices).write

    file-store := FileFleetStore.load tmp
        --default-broker-config=server-config
        --require-devices
        --cli=cli
    exercise-contract file-store tmp --server-config=server-config --cli=cli

    reloaded := FileFleetStore.load tmp
        --default-broker-config=server-config
        --require-devices
        --cli=cli
    expect-final-state reloaded

initial-groups cli/TestCli -> Map:
  return {
    DEFAULT-GROUP: PodReference.parse "initial@latest" --cli=cli,
  }

initial-devices -> List:
  return [
    DeviceFleet
        --id=(Uuid.parse DEVICE-ID)
        --name="device"
        --group=DEFAULT-GROUP,
  ]

exercise-contract store/FleetStore tmp/string
    --server-config/ServerConfigHttp
    --cli/TestCli:
  artemis := Artemis
      --cli=cli
      --tmp-directory=tmp
      --server-config=server-config
  fleet := Fleet.with-store store artemis
      --cli=cli
      --no-validate-organization

  staging := PodReference.parse "staging@latest" --cli=cli
  production := PodReference.parse "production@v1" --cli=cli
  fleet.add-group "staging" staging
  expect-equals "staging@latest" "$(store.group-pods["staging"])"

  moved := fleet.move-devices
      --ids={(Uuid.parse DEVICE-ID)}
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
