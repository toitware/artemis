// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ar
import bytes
import cli
import crypto.sha256
import host.pipe
import host.file
import host.directory
import io

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
import watchdog show Watchdog WatchdogServiceClient

import ..utils show decode-server-config
import ..service show run-artemis
import ..check-in show check-in-setup
import ..device
import ..storage show Storage
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
  watchdog-provider := watchdog.WatchdogServiceProvider
      --system-watchdog=NullWatchdog
  watchdog-provider.install

  client/WatchdogServiceClient := (WatchdogServiceClient).open as WatchdogServiceClient
  watchdog := client.create "toit.io/artemis"
  watchdog.start --s=WATCHDOG-TIMEOUT-S

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

    storage := StorageHost

    while true:
      device := Device
          --id=artemis-device.id
          --hardware-id=artemis-device.hardware-id
          --organization-id=artemis-device.organization-id
          --firmware-state=config
          --storage=storage
      check-in-setup --assets=identity --device=device
      server-config := decode-server-config "broker" identity
      sleep-duration := run-artemis
          device
          server-config
          --watchdog=watchdog
          --storage=storage
      sleep sleep-duration
      print

class StorageHost extends Storage:
  container-list-images -> List:
    return []

  container-write-image --id/uuid.Uuid --size/int --reader/io.Reader -> uuid.Uuid:
    throw "UNIMPLEMENTED"

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
    // TODO(florian): get the target-location.
    with-tmp-directory: | dir/string |
      (Firmware content_).write-into --dir=dir

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

class Firmware:
  static PART-HEADER_ ::= 0
  static PART-RUN-IMAGE_ ::= 1
  static PART-CONFIG_ ::= 2
  static PART-NAME-TO-UUID-MAPPING_ ::= 3
  static PART-STARTUP-IMAGES_ ::= 4
  static PART-BUNDLED-IMAGES_ ::= 5

  bits_/ByteArray

  constructor .bits_:

  part_ part/int -> ByteArray:
    from := io.LITTLE-ENDIAN.int32 bits_ (part * 8)
    to := io.LITTLE-ENDIAN.int32 bits_ (part * 8 + 4)
    return bits_[from..to]

  run-image -> ByteArray:
    return part_ PART-RUN-IMAGE_

  config -> ByteArray:
    return part_ PART-CONFIG_

  name-to-uuid-mapping -> Map:
    return ubjson.decode (part_ PART-NAME-TO-UUID-MAPPING_)

  startup-images -> Map:
    return read-images_ (part_ PART-STARTUP-IMAGES_)

  bundled-images -> Map:
    return read-images_ (part_ PART-BUNDLED-IMAGES_)

  read-images_ part/ByteArray -> Map:
    result := {:}
    reader := ar.ArReader (io.Reader part)
    while file/ar.ArFile := reader.next:
      result[file.name] = file.content
    return result

  write-into --dir/string:
    file.write-content --path="$dir/run-image" run-image
    file.write-content --path="$dir/config.ubjson" config
    directory.mkdir --recursive "$dir/startup-images"
    mapping := name-to-uuid-mapping
    startup-images.do: | name/string content/ByteArray |
      uuid := mapping[name]
      file.write-content --path="$dir/startup-images/$uuid" content
    directory.mkdir --recursive "$dir/bundled-images"
    bundled-images.do: | name string content/ByteArray |
      uuid := mapping[name]
      file.write-content --path="$dir/bundled-images/$uuid" content

