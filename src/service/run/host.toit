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

import ..utils show decode_server_config
import ..service show run_artemis
import ..check_in show check_in_setup
import ..device
import ...cli.artemis show Artemis
import ...cli.cache as cli
import ...cli.device as artemis_device
import ...cli.firmware as fw
import ...cli.pod
import ...cli.sdk
import ...cli.ui show Ui ConsoleUi
import ...cli.utils

main arguments:
  cache := cli.Cache --app_name="artemis"
  root_cmd := cli.Command "root"
      --options=[
        cli.OptionString "pod"
            --type="file"
            --required,
        cli.OptionString "identity"
            --type="file"
            --required,
      ]
      --run=:: run_host
          --pod_path=it["pod"]
          --identity_path=it["identity"]
          --cache=cache
  root_cmd.run arguments

run_host --pod_path/string --identity_path/string --cache/cli.Cache -> none:
  ui := ConsoleUi
  with_tmp_directory: | tmp_dir |
    pod := Pod.parse pod_path --tmp_directory=tmp_dir --ui=ui
    run_host --pod=pod --identity_path=identity_path --cache=cache

run_host --pod/Pod --identity_path/string --cache/cli.Cache -> none:
  identity := read_base64_ubjson identity_path
  identity["artemis.broker"] = tison.encode identity["artemis.broker"]
  identity["broker"] = tison.encode identity["broker"]
  device_identity := identity["artemis.device"]

  artemis_device := artemis_device.Device
      --hardware_id=uuid.parse device_identity["hardware_id"]
      --organization_id=uuid.parse device_identity["organization_id"]
      --id=uuid.parse device_identity["device_id"]

  firmware := fw.Firmware
      --pod=pod
      --device=artemis_device
      --cache=cache
  encoded_firmware_description := firmware.encoded

  sdk_version := pod.sdk_version
  sdk := get_sdk sdk_version --cache=cache
  with_tmp_directory: | tmp_dir/string |
    asset_path := "$tmp_dir/artemis_asset"
    sdk.firmware_extract_container --assets
        --name="artemis"
        --envelope_path=pod.envelope_path
        --output_path=asset_path
    config_asset := sdk.assets_extract
        --name="device-config"
        --assets_path=asset_path
    config := json.decode config_asset

    config["firmware"] = encoded_firmware_description

    service := FirmwareServiceProvider firmware.content.bits
    service.install

    while true:
      device := Device
          --id=artemis_device.id
          --hardware_id=artemis_device.hardware_id
          --organization_id=artemis_device.organization_id
          --firmware_state=config
      check_in_setup --assets=identity --device=device
      server_config := decode_server_config "broker" identity
      sleep_duration := run_artemis device server_config
      sleep sleep_duration
      print

// --------------------------------------------------------------------------

class FirmwareServiceProvider extends FirmwareServiceProviderBase:
  content_/ByteArray?

  constructor .content_:
    super "system/firmware/artemis" --major=0 --minor=1

  is_validation_pending -> bool:
    return false

  is_rollback_possible -> bool:
    return false

  validate -> bool:
    throw "UNIMPLEMENTED"

  rollback -> none:
    throw "UNIMPLEMENTED"

  upgrade -> none:
    // TODO(kasper): Ignored for now.

  config_ubjson -> ByteArray:
    return ByteArray 0

  config_entry key/string -> any:
    return null

  content:
    // TODO(kasper): Avoid this copy. We need it right now
    // because otherwise we run into trouble because we
    // seem to receive a 'proxy', not a proper external
    // byte array on the other side.
    return content_.copy

  uri -> string?:
    return null

  firmware_writer_open client/int from/int to/int -> FirmwareWriter:
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

  on_closed -> none:
    if not view_: return
    view_ = null
