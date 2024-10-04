// Copyright (C) 2024 Toitware ApS. All rights reserved.

import system.assets
import system.firmware

import encoding.base64
import encoding.tison
import encoding.ubjson

import log
import uuid show Uuid
import watchdog.provider as watchdog
import watchdog show WatchdogServiceClient Watchdog

import .null-watchdog
import .null-pin-trigger
import ..device
import ..service show run-artemis
import ..storage show Storage
import ..utils show decode-server-config
import ..watchdog

main arguments:
  watchdog-provider := watchdog.WatchdogServiceProvider --system-watchdog=NullWatchdog
  watchdog-provider.install

  client/WatchdogServiceClient := (WatchdogServiceClient).open as WatchdogServiceClient
  watchdog := client.create "toit.io/artemis"
  watchdog.start --s=WATCHDOG-TIMEOUT-S

  firmware-description := ubjson.decode (device-specific "parts")
  end := firmware-description.last["to"]
  firmware-ubjson := ubjson.encode {
    "device-specific" : firmware.config.ubjson,
    "checksum"        : checksum end,
  }
  encoded-firmware-description := base64.encode firmware-ubjson

  artemis-assets ::= assets.decode
  config := ubjson.decode (artemis-assets["device-config"])
  config["firmware"] = encoded-firmware-description

  storage := Storage

  artemis-device-map := device-specific "artemis.device"
  device := Device
      --id=Uuid.parse artemis-device-map["device_id"]
      --hardware-id=Uuid.parse artemis-device-map["hardware_id"]
      --organization-id=Uuid.parse artemis-device-map["organization_id"]
      --firmware-state=config
      --storage=storage

  recovery-urls-encoded := artemis-assets.get "recovery-urls"
  recovery-urls/List? :=
      recovery-urls-encoded and (tison.decode recovery-urls-encoded)

  server-config := decode-server-config "broker" artemis-assets
  sleep-duration := run-artemis device server-config
      --recovery-urls=recovery-urls
      --watchdog=watchdog
      --storage=storage
      --pin-trigger-manager=NullPinTriggerManager
  watchdog.stop
  print
  print
  __deep-sleep__ sleep-duration.in-ms

device-specific name/string -> any:
  return firmware.config[name]

checksum end/int -> ByteArray:
  firmware.map: | current/firmware.FirmwareMapping? |
    bytes := ByteArray 32
    if current: current.copy end (end + bytes.size) --into=bytes
    return bytes
  unreachable
