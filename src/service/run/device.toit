// Copyright (C) 2022 Toitware ApS. All rights reserved.

import system.assets
import system.firmware

import encoding.base64
import encoding.ubjson
import log

import ..check_in show check_in_setup
import ..device
import ..network show NetworkManager
import ..service show run_artemis
import ..utils show decode_server_config

device_specific_ name/string -> any:
  return firmware.config[name]

main arguments:
  artemis_assets ::= assets.decode
  server_config := decode_server_config "broker" artemis_assets

  artemis_device := device_specific_ "artemis.device"
  device_id := artemis_device["device_id"]
  organization_id := artemis_device["organization_id"]

  check_in_setup artemis_assets artemis_device

  firmware_description := ubjson.decode (device_specific_ "parts")
  end := firmware_description.last["to"]
  firmware_ubjson := ubjson.encode {
    "device-specific" : firmware.config.ubjson,
    "checksum"        : checksum end,
  }
  encoded_firmware_description := base64.encode firmware_ubjson

  config := ubjson.decode (artemis_assets["device-config"])
  config["firmware"] = encoded_firmware_description

  device := Device --id=device_id --organization_id=organization_id --firmware_state=config
  network_manager := NetworkManager log.default device
  network_manager.install

  sleep_duration := run_artemis device server_config
  __deep_sleep__ sleep_duration.in_ms

checksum end/int -> ByteArray:
  firmware.map: | current/firmware.FirmwareMapping? |
    bytes := ByteArray 33
    if current: current.copy end (end + bytes.size) --into=bytes
    return bytes
  unreachable
