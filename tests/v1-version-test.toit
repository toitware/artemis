// Copyright (C) 2026 Toitware ApS. All rights reserved.

import artemis.cli.device show Device
import artemis.shared.api-version show
    is-artemis-v1-version
    parse-artemis-version
import expect show *
import uuid show Uuid

main:
  test-versions
  test-identities

test-versions:
  alpha := parse-artemis-version "v1.0.0-alpha.1"
  expect-equals 1 alpha.major
  expect-equals ["alpha", "1"] alpha.pre-releases

  beta := parse-artemis-version "1.0.0-beta.2"
  expect-equals 1 beta.major
  expect-equals ["beta", "2"] beta.pre-releases

  expect-null (parse-artemis-version null)
  expect-null (parse-artemis-version "main")

  expect (is-artemis-v1-version "v1.0.0-alpha")
  expect (is-artemis-v1-version "v1.0.0-beta.1")
  expect (is-artemis-v1-version "v1.0.0-rc.2")
  expect (is-artemis-v1-version "v1.0.0")
  expect-not (is-artemis-v1-version "v0.34.1")
  expect-not (is-artemis-v1-version "v2.0.0-alpha.1")
  expect-not (is-artemis-v1-version null)

test-identities:
  device := Device
      --id=Uuid.parse "eb45c662-356c-4bea-ad8c-ede37688fddf"
      --organization-id=Uuid.parse "4b6d9e35-cae9-44c0-8da0-6b0e485987e2"

  v1-identity := device.to-json-identity
  expect-not (v1-identity["artemis.device"].contains "hardware_id")
  expect-equals "$device.id" v1-identity["artemis.device"]["device_id"]
