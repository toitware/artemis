// Copyright (C) 2022 Toitware ApS. All rights reserved.

import system.assets
import system.firmware

import esp32

import encoding.base64
import encoding.ubjson
import log
import uuid
import watchdog.provider as watchdog

import ..check-in show check-in-setup
import ..device
import ..network show NetworkManager
import ..service show run-artemis
import ..utils show decode-server-config
import ..watchdog
import ..time

import gpio

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
  start-us = Time.monotonic-us - 70_000
  now "Started"
  watchdog-provider := watchdog.WatchdogServiceProvider
      --granularity-ms=WATCHDOG-GRANULARITY-MS
  watchdog-provider.install
  now "Watchdog installed"

  // No need to store the returned dog, as we expect to transition out
  // of startup before it needs to be fed.
  WatchdogManager.transition-to WatchdogManager.STATE-STARTUP
  now "Watchdog transitioned"

  firmware-description := ubjson.decode (device-specific "parts")
  now "Device-specific parts decoded"
  end := firmware-description.last["to"]
  firmware-ubjson := ubjson.encode {
    "device-specific" : firmware.config.ubjson,
    "checksum"        : checksum end,
  }
  now "Firmware-ubjson created"
  encoded-firmware-description := base64.encode firmware-ubjson
  now "Firmware-description encoded"

  artemis-assets ::= assets.decode
  config := ubjson.decode (artemis-assets["device-config"])
  config["firmware"] = encoded-firmware-description
  now "Assets decoded"

  artemis-device-map := device-specific "artemis.device"
  now "Device-specific obtained"
  device := Device
      --id=uuid.parse artemis-device-map["device_id"]
      --hardware-id=uuid.parse artemis-device-map["hardware_id"]
      --organization-id=uuid.parse artemis-device-map["organization_id"]
      --firmware-state=config
  now "Device created"
  check-in-setup --assets=artemis-assets --device=device

  network-manager := NetworkManager log.default device
  network-manager.install
  now "Network manager installed"

  server-config := decode-server-config "broker" artemis-assets
  now "Server-config decoded"
  sleep-duration := run-artemis device server-config
      --cause=ESP32-WAKEUP-CAUSES.get esp32.wakeup-cause
  now "Sleep"
  __deep-sleep__ sleep-duration.in-ms

device-specific name/string -> any:
  return firmware.config[name]

checksum end/int -> ByteArray:
  firmware.map: | current/firmware.FirmwareMapping? |
    bytes := ByteArray 33
    if current: current.copy end (end + bytes.size) --into=bytes
    return bytes
  unreachable
