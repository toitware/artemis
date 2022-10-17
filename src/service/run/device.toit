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
  device := report_status_setup decoded firmware.config["artemis.device"]
  // TODO(kasper): We're missing the correct checksum. This
  // means that the firmware will appear outdated when we
  // synchronize with the cloud.
  update := ubjson.encode {
    "config"   : firmware.config.ubjson,
    "checksum" : ByteArray 33,
  }
  firmware := base64.encode update
  run_artemis device broker --firmware=firmware
