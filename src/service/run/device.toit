// Copyright (C) 2022 Toitware ApS. All rights reserved.

import system.assets
import system.firmware

import encoding.base64
import encoding.ubjson

import ..utils show decode_broker_config
import ..check_in show check_in_setup
import ..service show run_artemis
import ..device

main arguments:
  decoded ::= assets.decode
  broker_config := decode_broker_config "broker" decoded

  check_in_setup decoded firmware.config["artemis.device"]

  firmware_description := ubjson.decode firmware.config["parts"]
  end := firmware_description.last["to"]

  update := ubjson.encode {
    "config"   : firmware.config.ubjson,
    "checksum" : checksum end,
  }

  device_id := firmware.config["artemis.device"]["device_id"]
  firmware := base64.encode update
  device := Device --id=device_id --firmware=firmware
  run_artemis device broker_config

checksum end/int -> ByteArray:
  firmware.map: | current/firmware.FirmwareMapping? |
    bytes := ByteArray 33
    if current: current.copy end (end + bytes.size) --into=bytes
    return bytes
  unreachable
