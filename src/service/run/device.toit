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

  firmware_description := ubjson.decode firmware.config["firmware"]
  end := firmware_description.last["to"]

  update := ubjson.encode {
    "config"   : firmware.config.ubjson,
    "checksum" : checksum end,
  }
  firmware := base64.encode update
  run_artemis device broker --firmware=firmware

checksum end/int -> ByteArray:
  firmware.map: | current/firmware.FirmwareMapping? |
    bytes := ByteArray 33
    if current: current.copy end (end + bytes.size) --into=bytes
    return bytes
  unreachable
