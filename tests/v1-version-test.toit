// Copyright (C) 2026 Toitware ApS. All rights reserved.

import artemis.cli.device show Device
import artemis.shared.api-version show
    artemis-version-major
    is-artemis-v1-version
    is-supported-artemis-target
import expect show *
import uuid show Uuid

main:
  test-versions
  test-identities

test-versions:
  expect-equals 1 (artemis-version-major "v1.0.0-alpha.1")
  expect-equals 1 (artemis-version-major "1.0.0-beta.2")
  expect-equals 0 (artemis-version-major "v0.34.1")
  expect-null (artemis-version-major null)
  expect-null (artemis-version-major "main")

  expect (is-artemis-v1-version "v1.0.0-alpha")
  expect (is-artemis-v1-version "v1.0.0-beta.1")
  expect (is-artemis-v1-version "v1.0.0-rc.2")
  expect (is-artemis-v1-version "v1.0.0")
  expect-not (is-artemis-v1-version "v0.34.1")
  expect-not (is-artemis-v1-version null)

  expect (is-supported-artemis-target 0 null)
  expect (is-supported-artemis-target 0 "v0.34.1")
  expect (is-supported-artemis-target 0 "v1.0.0-alpha.1")
  expect (is-supported-artemis-target 1 "v1.0.0-alpha.1")
  expect-not (is-supported-artemis-target 1 "v0.34.1")
  expect-not (is-supported-artemis-target 1 null)
  expect-not (is-supported-artemis-target 1 "v2.0.0-alpha.1")

test-identities:
  device := Device
      --id=Uuid.parse "eb45c662-356c-4bea-ad8c-ede37688fddf"
      --organization-id=Uuid.parse "4b6d9e35-cae9-44c0-8da0-6b0e485987e2"

  old-identity := device.to-json-identity --artemis-major=0
  expect-equals "$device.id" old-identity["artemis.device"]["hardware_id"]

  v1-identity := device.to-json-identity --artemis-major=1
  expect-not (v1-identity["artemis.device"].contains "hardware_id")
  expect-equals "$device.id" v1-identity["artemis.device"]["device_id"]
