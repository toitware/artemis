// Copyright (C) 2026 Toitware ApS. All rights reserved.

import artemis.service.firmware show Firmware
import encoding.base64
import encoding.ubjson
import expect show *

main:
  parts := [{
    "type": "config",
    "from": 0,
    "to": 128,
  }]
  device-specific := ubjson.encode {
    "artemis.device": {
      "device_id": "eb45c662-356c-4bea-ad8c-ede37688fddf",
      "organization_id": "4b6d9e35-cae9-44c0-8da0-6b0e485987e2",
    },
    "parts": ubjson.encode parts,
  }
  checksum := #[1, 2, 3, 4]
  encoded := base64.encode (ubjson.encode {
    "device-specific": device-specific,
    "checksum": checksum,
  })

  firmware := Firmware.encoded encoded
  expect-bytes-equal device-specific firmware.device-specific-encoded
  expect-equals 1 firmware.parts.size
  expect-equals "config" firmware.parts.first["type"]
  expect-equals 0 firmware.parts.first["from"]
  expect-equals 128 firmware.parts.first["to"]
  expect-bytes-equal checksum firmware.checksum
  expect-equals 132 firmware.size
