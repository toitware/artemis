// Copyright (C) 2022 Toitware ApS. All rights reserved.

import system.assets
import system.firmware

import esp32

import encoding.base64
import encoding.tison
import encoding.ubjson

import log
import uuid show Uuid
import watchdog.provider as watchdog
import watchdog show WatchdogServiceClient Watchdog

import ..device
import ..esp32.pin-trigger
import ..network show NetworkManager
import ..service show run-artemis
import ..storage show Storage
import ..utils show decode-server-config
import ..watchdog

ESP32-WAKEUP-CAUSES ::= {
  esp32.WAKEUP-EXT1     : "gpio",
  esp32.WAKEUP-TIMER    : "timer",
  esp32.WAKEUP-TOUCHPAD : "touchpad",
  esp32.WAKEUP-ULP      : "ulp",
}

// Allow Artemis to run critical tasks that do not yield for up
// to 10s. If we run with the default granularity, we may experience
// issues with the firmware update task that uses relatively slow
// flash erase operations.
WATCHDOG-GRANULARITY-MS ::= 10_000 * 2

main arguments:
  watchdog-provider := watchdog.WatchdogServiceProvider
      --granularity-ms=WATCHDOG-GRANULARITY-MS
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

  network-manager := NetworkManager log.default device
  network-manager.install

  server-config := decode-server-config "broker" artemis-assets
  sleep-duration := run-artemis device server-config
      --recovery-urls=recovery-urls
      --watchdog=watchdog
      --cause=ESP32-WAKEUP-CAUSES.get esp32.wakeup-cause
      --storage=storage
      --pin-trigger-manager=PinTriggerManagerEsp32
  __deep-sleep__ sleep-duration.in-ms

device-specific name/string -> any:
  return firmware.config[name]

checksum end/int -> ByteArray:
  firmware.map: | current/firmware.FirmwareMapping? |
    bytes := ByteArray 33
    if current: current.copy end (end + bytes.size) --into=bytes
    return bytes
  unreachable
