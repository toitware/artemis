// Copyright (C) 2026 Toit contributors.

import expect show *
import uuid show Uuid

import artemis.cli.fleet show DEFAULT-GROUP DeviceFleet DevicesFile FleetFile
import artemis.cli.fleet-storage show FleetStorage
import artemis.cli.pod-registry show PodReference
import artemis.cli.server-config show ServerConfig ServerConfigHttp
import .utils show TestCli

main:
  test-fleet-config-round-trip
  test-devices-round-trip
  test-pod-spec-round-trip
  test-identity-round-trip
  test-init-only-uses-storage

test-fleet-config-round-trip:
  storage := InMemoryFleetStorage
  cli := TestCli

  fleet-id := Uuid.parse "12345678-1234-1234-1234-123456789abc"
  organization-id := Uuid.parse "98765432-4321-4321-4321-cba987654321"
  broker-config := ServerConfigHttp "test-broker"
      --host="localhost"
      --port=1234
      --path="/"
      --root-certificate-ders=null
      --device-headers=null
      --admin-headers=null
  group-pods := {
    DEFAULT-GROUP: PodReference.parse "my-pod@latest" --cli=cli,
    "alt": PodReference.parse "alt-pod@stable" --cli=cli,
  }
  original := FleetFile
      --id=fleet-id
      --organization-id=organization-id
      --group-pods=group-pods
      --is-reference=false
      --broker-name=broker-config.name
      --migrating-from=[]
      --servers={broker-config.name: broker-config}
      --recovery-urls=["https://example.com/recover-$(fleet-id).json"]

  // Round-trip: write, then read back via parse.
  original.write storage
  expect storage.has-fleet-config
  loaded := FleetFile.parse storage --default-broker-config=broker-config --cli=cli

  expect-equals original.id loaded.id
  expect-equals original.organization-id loaded.organization-id
  expect-equals original.broker-name loaded.broker-name
  expect-equals original.migrating-from loaded.migrating-from
  expect-equals original.recovery-urls loaded.recovery-urls
  expect-equals original.group-pods.size loaded.group-pods.size
  original.group-pods.do: | name/string ref/PodReference |
    expect-equals ref.to-string (loaded.group-pods[name] as PodReference).to-string
  expect-equals original.servers.keys loaded.servers.keys

test-devices-round-trip:
  storage := InMemoryFleetStorage
  cli := TestCli

  devices := [
    DeviceFleet
        --id=Uuid.parse "11111111-1111-1111-1111-111111111111"
        --group=DEFAULT-GROUP
        --name="alpha"
        --aliases=["a"],
    DeviceFleet
        --id=Uuid.parse "22222222-2222-2222-2222-222222222222"
        --group="other"
        --name="beta"
        --aliases=[],
  ]
  original := DevicesFile devices
  original.write storage
  expect storage.has-devices

  loaded := DevicesFile.parse storage --cli=cli
  expect-equals original.devices.size loaded.devices.size
  loaded-by-id := {:}
  loaded.devices.do: | d/DeviceFleet | loaded-by-id[d.id] = d
  original.devices.do: | d/DeviceFleet |
    other/DeviceFleet := loaded-by-id[d.id]
    expect-equals d.name other.name
    expect-equals d.group other.group
    expect-equals d.aliases other.aliases

test-pod-spec-round-trip:
  storage := InMemoryFleetStorage
  expect-not (storage.has-pod-spec "my-pod")
  payload := "name: hello\nsdk: latest\n".to-byte-array
  storage.write-pod-spec "my-pod" payload
  expect (storage.has-pod-spec "my-pod")
  expect-equals payload storage.pod-specs_["my-pod"]

test-identity-round-trip:
  storage := InMemoryFleetStorage
  device-id := Uuid.parse "33333333-3333-3333-3333-333333333333"
  contents := #[1, 2, 3, 4, 5]
  path := storage.write-identity --device-id=device-id contents --output-directory="/dev/null"
  expect (path.contains "$device-id")
  expect-equals contents storage.identities_[device-id]

test-init-only-uses-storage:
  // Confirm the in-memory storage exposes a believable empty state.
  storage := InMemoryFleetStorage
  expect-not storage.has-fleet-config
  expect-not storage.has-devices
  expect storage.supports-devices
  expect-null storage.display-root

/**
An in-memory $FleetStorage used by tests to confirm that the storage
  contract is sufficient (no hidden filesystem assumptions).
*/
class InMemoryFleetStorage implements FleetStorage:
  fleet-config_/Map? := null
  devices_/Map? := null
  pod-specs_/Map ::= {:}
  identities_/Map ::= {:}

  display-root -> string?: return null
  supports-devices -> bool: return true

  has-fleet-config -> bool: return fleet-config_ != null
  read-fleet-config -> Map: return fleet-config_
  write-fleet-config config/Map -> none: fleet-config_ = config

  has-devices -> bool: return devices_ != null
  read-devices -> Map: return devices_
  write-devices devices/Map -> none: devices_ = devices

  has-pod-spec name/string -> bool: return pod-specs_.contains name
  write-pod-spec name/string contents/ByteArray -> none:
    pod-specs_[name] = contents

  write-identity --device-id/Uuid contents/ByteArray --output-directory/string -> string:
    identities_[device-id] = contents
    return "$output-directory/$(device-id).identity"
