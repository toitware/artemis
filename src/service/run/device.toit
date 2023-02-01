// Copyright (C) 2022 Toitware ApS. All rights reserved.

import system.assets
import system.firmware

import encoding.base64
import encoding.ubjson

import ..utils show decode_server_config
import ..check_in show check_in_setup
import ..service show run_artemis
import ..device

device_specific_ name/string -> any:
  return firmware.config[name]

main arguments:
  artemis_assets ::= assets.decode
  server_config := decode_server_config "broker" artemis_assets

  artemis_device := device_specific_ "artemis.device"
  device_id := artemis_device["device_id"]

  check_in_setup artemis_assets artemis_device

  firmware_description := ubjson.decode (device_specific_ "parts")
  end := firmware_description.last["to"]
  firmware_ubjson := ubjson.encode {
    "config"   : firmware.config.ubjson,
    "checksum" : checksum end,
  }
  firmware_encoded := base64.encode firmware_ubjson

  config := ubjson.decode (artemis_assets["device-config"])
  config["firmware"] = firmware_encoded

  device := Device --id=device_id --config=config
  run_artemis device server_config

checksum end/int -> ByteArray:
  firmware.map: | current/firmware.FirmwareMapping? |
    bytes := ByteArray 33
    if current: current.copy end (end + bytes.size) --into=bytes
    return bytes
  unreachable
