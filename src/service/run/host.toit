// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import host.pipe
import host.file
import bytes
import crypto.sha256

import system.assets
import system.services

import system.base.firmware show FirmwareWriter FirmwareServiceProviderBase

import encoding.json
import encoding.ubjson
import encoding.base64
import encoding.tison
import encoding.hex
import uuid

import watchdog.provider as watchdog

import ..utils show decode-server-config
import ..service show run-artemis
import ..check-in show check-in-setup
import ..device
import ..watchdog
import ...cli.artemis show Artemis
import ...cli.cache as cli
import ...cli.device as artemis-device
import ...cli.firmware as fw
import ...cli.pod
import ...cli.sdk
import ...cli.ui show Ui ConsoleUi
import ...cli.utils

main arguments:
  cache := cli.Cache --app-name="artemis"
  root-cmd := cli.Command "root"
      --options=[
        cli.OptionString "pod"
            --type="file"
            --required,
        cli.OptionString "identity"
            --type="file"
            --required,
      ]
      --run=:: run-host
          --pod-path=it["pod"]
          --identity-path=it["identity"]
          --cache=cache
  root-cmd.run arguments

run-host --pod-path/string --identity-path/string --cache/cli.Cache -> none:
  ui := ConsoleUi
  with-tmp-directory: | tmp-dir |
    pod := Pod.parse pod-path --tmp-directory=tmp-dir --ui=ui
    run-host --pod=pod --identity-path=identity-path --cache=cache

/**
A system watchdog that ignores all calls to it.
*/
class NullWatchdog implements watchdog.SystemWatchdog:
  start --ms/int:
  feed -> none:
  stop -> none:
  reboot -> none:

run-host --pod/Pod --identity-path/string --cache/cli.Cache -> none:
  (watchdog.WatchdogServiceProvider --system-watchdog=NullWatchdog).install

  identity := read-base64-ubjson identity-path
  identity["artemis.broker"] = tison.encode identity["artemis.broker"]
  identity["broker"] = tison.encode identity["broker"]
  device-identity := identity["artemis.device"]

  artemis-device := artemis-device.Device
      --hardware-id=uuid.parse device-identity["hardware_id"]
      --organization-id=uuid.parse device-identity["organization_id"]
      --id=uuid.parse device-identity["device_id"]

  firmware := fw.Firmware
      --pod=pod
      --device=artemis-device
      --cache=cache
  encoded-firmware-description := firmware.encoded

  sdk-version := pod.sdk-version
  sdk := get-sdk sdk-version --cache=cache
  with-tmp-directory: | tmp-dir/string |
    asset-path := "$tmp-dir/artemis_asset"
    sdk.firmware-extract-container --assets
        --name="artemis"
        --envelope-path=pod.envelope-path
        --output-path=asset-path
    config-asset := sdk.assets-extract
        --name="device-config"
        --assets-path=asset-path
    config := json.decode config-asset

    config["firmware"] = encoded-firmware-description

    service := FirmwareServiceProvider firmware.content.bits
    service.install

    while true:
      // Reset the watchdog manager. We need to do this, as the scheduler
      // expects to be in `STATE-STARTUP`.
      // We don't use the returned dogs, as we expect to migrate to a
      // different state before they need to be fed.
      WatchdogManager.transition-to WatchdogManager.STATE-STARTUP
      device := Device
          --id=artemis-device.id
          --hardware-id=artemis-device.hardware-id
          --organization-id=artemis-device.organization-id
          --firmware-state=config
      check-in-setup --assets=identity --device=device
      server-config := decode-server-config "broker" identity
      sleep-duration := run-artemis device server-config
      sleep sleep-duration
      print

// --------------------------------------------------------------------------

class FirmwareServiceProvider extends FirmwareServiceProviderBase:
  content_/ByteArray?

  constructor .content_:
    super "system/firmware/artemis" --major=0 --minor=1

  is-validation-pending -> bool:
    return false

  is-rollback-possible -> bool:
    return false

  validate -> bool:
    throw "UNIMPLEMENTED"

  rollback -> none:
    throw "UNIMPLEMENTED"

  upgrade -> none:
    // TODO(kasper): Ignored for now.

  config-ubjson -> ByteArray:
    return ByteArray 0

  config-entry key/string -> any:
    return null

  content:
    // TODO(kasper): Avoid this copy. We need it right now
    // because otherwise we run into trouble because we
    // seem to receive a 'proxy', not a proper external
    // byte array on the other side.
    return content_.copy

  uri -> string?:
    return null

  firmware-writer-open client/int from/int to/int -> FirmwareWriter:
    return FirmwareWriter_ this client from to

class FirmwareWriter_ extends services.ServiceResource implements FirmwareWriter:
  static image/ByteArray := #[]
  view_/ByteArray? := null
  cursor_/int := 0

  constructor provider/FirmwareServiceProvider client/int from/int to/int:
    if to > image.size: image = image + (ByteArray to - image.size: random 0x100)
    view_ = image[from..to]
    super provider client

  write bytes/ByteArray from=0 to=bytes.size -> none:
    view_.replace cursor_ bytes[from..to]
    cursor_ += to - from

  pad size/int value/int -> none:
    to := cursor_ + size
    view_.fill --from=cursor_ --to=to value
    cursor_ = to

  flush -> int:
    // Everything is already flushed.
    return 0

  commit checksum/ByteArray? -> none:
    print "Got a grand total of $image.size bytes"
    sha := sha256.Sha256
    sha.add image[..image.size - 32]
    print "Computed checksum = $(hex.encode sha.get)"
    print "Provided checksum = $(hex.encode image[image.size - 32..])"
    view_ = null

  on-closed -> none:
    if not view_: return
    view_ = null
