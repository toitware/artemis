// Copyright (C) 2026 Toit contributors. All rights reserved.

import artemis.cli.fleet show
    DEFAULT-GROUP
    DeviceFleet
    Fleet
import artemis.cli.file-fleet-store show FileFleetStoreStrategy
import artemis.cli.directory-fleet-store show DirectoryFleetStoreStrategy
import artemis.cli.fleet-store show FleetStore
import artemis.cli.pod-registry show PodReference
import artemis.cli.server-config show ServerConfigHttp
import artemis.cli.utils show create-directory-atomically
import artemis.shared.scope show Scope
import expect show *
import fs
import host
import host.directory
import host.file
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
  test-directory-creation
  test-directory-creation-failure
  test-directory-creation-existing-target
  test-directory-creation-late-target
  test-directory-creation-return
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

    directory-strategy := DirectoryFleetStoreStrategy --root="$tmp/fleet" --cli=cli
    directory-store := directory-strategy.create
        --id=Uuid.parse FLEET-ID
        --group-pods=initial-groups cli
        --devices=initial-devices
    exercise-contract directory-store --cli=cli
    expect-final-state directory-strategy.open

    reference-path := "$tmp/fleet-reference.json"
    file-store.write-reference --path=reference-path
    reference-strategy := FileFleetStoreStrategy
        --root=reference-path
        --legacy-default-broker-config=server-config
        --cli=cli
    reference := reference-strategy.open-reference
    expect-equals FLEET-ID "$reference.id"
    expect-equals server-config.name reference.broker-name

test-directory-creation:
  host.with-tmp-directory: | tmp/string |
    target := fs.join tmp "parent/fleet"
    staging-path := ""
    create-directory-atomically target --if-error=(: unreachable): | staging/string |
      staging-path = staging
      expect-equals (fs.dirname target) (fs.dirname staging)
      expect-not (file.is-directory target)
      directory.mkdir (fs.join staging "nested")
      file.write-contents --path=(fs.join staging "nested/state") "ready"
      expect-not (file.is-directory target)
    expect-equals "ready" (file.read-contents (fs.join target "nested/state")).to-string
    expect-equals null (file.stat staging-path --no-follow-links)

test-directory-creation-failure:
  host.with-tmp-directory: | tmp/string |
    target := fs.join tmp "fleet"
    staging-path := ""
    calls := 0
    create-directory-atomically target
        --if-error=(: | error |
          expect-equals "population failed" error
          expect-equals null (file.stat staging-path --no-follow-links)
          calls++): | staging/string |
      staging-path = staging
      directory.mkdir (fs.join staging "nested")
      file.write-contents --path=(fs.join staging "nested/state") "partial"
      throw "population failed"
    expect-equals 1 calls
    expect-equals null (file.stat target --no-follow-links)

test-directory-creation-existing-target:
  ["file", "empty-directory", "populated-directory"].do: | kind/string |
    host.with-tmp-directory: | tmp/string |
      target := fs.join tmp "fleet"
      if kind == "file":
        file.write-contents --path=target "original"
      else:
        directory.mkdir target
        if kind == "populated-directory":
          file.write-contents --path=(fs.join target "state") "original"
      calls := 0
      create-directory-atomically target (: unreachable)
          --if-error=(: | error |
            expect-equals "Directory '$target' already exists." error
            calls++)
      expect-equals 1 calls
      if kind == "file":
        expect-equals "original" (file.read-contents target).to-string
      else:
        expect (file.is-directory target)
        if kind == "populated-directory":
          expect-equals "original" (file.read-contents (fs.join target "state")).to-string

test-directory-creation-late-target:
  host.with-tmp-directory: | tmp/string |
    target := fs.join tmp "fleet"
    staging-path := ""
    calls := 0
    create-directory-atomically target
        --if-error=(: | error |
          expect-equals "Directory '$target' already exists." error
          expect-equals null (file.stat staging-path --no-follow-links)
          calls++): | staging/string |
      staging-path = staging
      file.write-contents --path=(fs.join staging "state") "new"
      directory.mkdir target
    expect-equals 1 calls
    expect (file.is-directory target)
    expect-not (file.is-file (fs.join target "state"))

test-directory-creation-return:
  host.with-tmp-directory: | tmp/string |
    target := fs.join tmp "fleet"
    staging-path := ""
    try:
      create-directory-atomically target --if-error=(: unreachable): | staging/string |
        staging-path = staging
        file.write-contents --path=(fs.join staging "state") "partial"
        continue.with-tmp-directory
      expect false
    finally:
      expect-equals null (file.stat staging-path --no-follow-links)
      expect-equals null (file.stat target --no-follow-links)

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
