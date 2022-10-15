// Copyright (C) 2022 Toitware ApS. All rights reserved.

import system.assets
import system.firmware

import encoding.base64
import encoding.ubjson

import ..broker show decode_broker
import ..status show report_status_setup
import ..service show run_artemis

main arguments:
  decoded ::= assets.decode
  broker := decode_broker "broker" decoded
  device := report_status_setup decoded (firmware.config "artemis.device")
  // TODO(kasper): This is the wrong firmware description. It should be
  // the full base64 update string that contains the checksum and the
  // full config, but we probably need to compute this on the device on
  // the first boot after provisioning.
  update := ubjson.encode {
    "config": ubjson.encode {
      "firmware": firmware.config "firmware",
      // TODO(kasper): There is more.
    },
    // "checksum": ByteArray 33
  }
  firmware := base64.encode update
  run_artemis device broker --firmware=firmware
