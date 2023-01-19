// Copyright (C) 2022 Toitware ApS. All rights reserved.

import crypto.sha256
import host.file
import bytes
import log
import writer

import encoding.base64
import encoding.ubjson
import encoding.json

import .cache as cache

import .utils
import .utils.patch_build show build_diff_patch build_trivial_patch
import ..shared.utils.patch show Patcher PatchObserver

import .brokers.broker
import .firmware
import .program
import .sdk
import .ui

/**
Manages devices that have an Artemis service running on them.
*/
class Artemis:
  broker_/BrokerCli
  cache_/cache.Cache
  sdk_/Sdk

  constructor .broker_ .cache_ --sdk/Sdk?=null:
    // TODO(florian): make the sdk non-optional.
    if not sdk: sdk = Sdk
    sdk_ = sdk

  close:
    // Do nothing for now.
    // The brokers are not created here and should be closed outside.

  /**
  Maps a device selector (name or id) to its id.
  */
  device_selector_to_id name/string -> string:
    return name

  image_cache_id_ id/string -> string:
    return "$broker_.id/images/$id"

  app_install --device_id/string --app_name/string --application_path/string:
    program := CompiledProgram.application application_path --sdk=sdk_
    id := program.id
    cache_id := image_cache_id_ id
    cache_.get_directory_path cache_id: | store/cache.DirectoryStore |
      store.with_tmp_directory: | tmp_dir |
        // TODO(florian): do we want to rely on the cache, or should we
        // do a check to see if the files are really uploaded?
        broker_.upload_image --app_id=id --bits=32 program.image32
        file.write_content program.image32 --path="$tmp_dir/image32.bin"
        broker_.upload_image --app_id=id --bits=64 program.image64
        file.write_content program.image64 --path="$tmp_dir/image64.bin"
        store.move tmp_dir

    broker_.device_update_config --device_id=device_id: | config/Map |
      log.info "$(%08d Time.monotonic_us): Installing app: $app_name"
      apps := config.get "apps" --if_absent=: {:}
      apps[app_name] = {"id": id, "random": (random 1000)}
      config["apps"] = apps
      config

  app_uninstall --device_id/string --app_name/string:
    broker_.device_update_config --device_id=device_id: | config/Map |
      log.info "$(%08d Time.monotonic_us): Uninstalling app: $app_name"
      apps := config.get "apps"
      if apps: apps.remove app_name
      config

  config_set_max_offline --device_id/string --max_offline_seconds/int:
    broker_.device_update_config --device_id=device_id: | config/Map |
      log.info "$(%08d Time.monotonic_us): Setting max-offline to $(Duration --s=max_offline_seconds)"
      if max_offline_seconds > 0:
        config["max-offline"] = max_offline_seconds
      else:
        config.remove "max-offline"
      config

  firmware_create -> Firmware
      --identity/Map
      --wifi/Map
      --device_id/string
      --firmware_path/string
      --ui/Ui:
    with_tmp_directory: | tmp/string |
      artemis_assets_path := "$tmp/artemis.assets"
      sdk_.run_firmware_tool [
        "-e", firmware_path,
        "container", "extract",
        "-o", artemis_assets_path,
        "--part", "assets",
        "artemis"
      ]

      // TODO(kasper): Clean this up and provide a better error message.
      if not is_same_broker "broker" identity tmp artemis_assets_path sdk_:
        ui.error "not the same broker"
        ui.abort
      if not is_same_broker "artemis.broker" identity tmp artemis_assets_path sdk_:
        ui.error "not the same artemis broker"
        ui.abort

    firmware/Firmware? := null
    broker_.device_update_config --device_id=device_id: | config/Map |
      device := identity["artemis.device"]
      upgrade_to := compute_firmware_update_
          --device=device
          --wifi=wifi
          --envelope_path=firmware_path

      patches := upgrade_to.patches null
      patches.do: upload_ it
      firmware = upgrade_to

      // TODO(kasper): We actually don't have to update the device configuration
      // stored in the online database unless we think it may contain garbage.
      config["firmware"] = upgrade_to.encoded
      config

    return firmware

  firmware_update --device_id/string --firmware_path/string --ui/Ui -> none:
    broker_.device_update_config --device_id=device_id: | config/Map |
      upgrade_from/Firmware? := null
      existing := config.get "firmware"
      if existing: catch: upgrade_from = Firmware.encoded existing

      device := null
      if upgrade_from: device = upgrade_from.config "artemis.device"
      if device:
        existing_id := device.get "device_id"
        if device_id != existing_id:
          ui.error "Device id was wrong; expected $device_id but was $existing_id."
          device = null

      if not device:
        // Cannot proceed without an identity file.
        throw "Unclaimed device. Cannot proceed without an identity file."

      wifi := null
      if upgrade_from: wifi = upgrade_from.config "wifi"
      if not wifi:
        // Device has no way to connect.
        ui.error "Device has no way to connect."

      upgrade_to := compute_firmware_update_
          --device=device
          --wifi=wifi
          --envelope_path=firmware_path

      patches := upgrade_to.patches upgrade_from
      patches.do: upload_ it
      config["firmware"] = upgrade_to.encoded
      config

  // TODO(kasper): Turn this into a static method on Firmware?
  compute_firmware_update_ --device/Map --wifi/Map --envelope_path/string -> Firmware:
    unconfigured := extract_firmware_ envelope_path null sdk_
    encoded := unconfigured.encoded
    while true:
      config := ubjson.encode {
        "artemis.device" : device,
        "wifi"           : wifi,
        "parts"          : encoded,
      }

      configured := extract_firmware_ envelope_path config sdk_
      if configured.encoded == encoded:
        return Firmware configured config
      encoded = configured.encoded

  upload_ patch/FirmwarePatch -> none:
    trivial_id := id_ --to=patch.to_
    cache_key := "$broker_.id/patches/$trivial_id"
    // Unless it is already cached, always create/upload the trivial one.
    cache_.get cache_key: | store/cache.FileStore |
      trivial := build_trivial_patch patch.bits_
      broker_.upload_firmware --firmware_id=trivial_id trivial
      store.save_via_writer: | writer/writer.Writer |
        trivial.do: writer.write it

    if not patch.from_: return

    // Attempt to fetch the old trivial patch and use it to construct
    // the old bits so we can compute a diff from them.
    old_id := id_ --to=patch.from_
    cache_key = "$broker_.id/patches/$old_id"
    trivial_old := cache_.get cache_key: | store/cache.FileStore |
      downloaded := null
      catch: downloaded = broker_.download_firmware --id=old_id
      if not downloaded: return
      store.with_tmp_directory: | tmp_dir |
        file.write_content downloaded --path="$tmp_dir/patch"
        // TODO(florian): we don't have the chunk-size when downloading from the broker.
        store.move tmp_dir

    bitstream := bytes.Reader trivial_old
    patcher := Patcher bitstream null
    patch_writer := PatchWriter
    if not patcher.patch patch_writer: return
    // Build the old bits and check that we get the correct hash.
    old := patch_writer.buffer.bytes
    if old.size < patch_writer.size: old += ByteArray (patch_writer.size - old.size)
    sha := sha256.Sha256
    sha.add old
    if patch.from_ != sha.get: return

    diff_id := id_ --from=patch.from_ --to=patch.to_
    cache_key = "$broker_.id/patches/$diff_id"
    cache_.get cache_key: | store/cache.FileStore |
      // Build the diff and verify that we can apply it and get the
      // correct hash out before uploading it.
      diff := build_diff_patch old patch.bits_
      if patch.to_ != (compute_applied_hash_ diff old): return
      broker_.upload_firmware --firmware_id=diff_id diff
      store.save_via_writer: | writer/writer.Writer |
        diff.do: writer.write it

  static id_ --from/ByteArray?=null --to/ByteArray -> string:
    folder := base64.encode to --url_mode
    entry := from ? (base64.encode from --url_mode) : "none"
    return "$folder/$entry"

  static compute_applied_hash_ diff/List old/ByteArray -> ByteArray?:
    combined := diff.reduce --initial=#[]: | acc chunk | acc + chunk
    bitstream := bytes.Reader combined
    patcher := Patcher bitstream old
    writer := PatchWriter
    if not patcher.patch writer: return null
    sha := sha256.Sha256
    sha.add writer.buffer.bytes
    return sha.get

is_same_broker broker/string identity/Map tmp/string assets_path/string sdk/Sdk -> bool:
  broker_path := "$tmp/broker.json"
  sdk.run_assets_tool [
    "-e", assets_path,
    "get", "--format=tison",
    "-o", broker_path,
    "broker"
  ]
  // TODO(kasper): This is pretty crappy.
  x := ((json.stringify identity["broker"]) + "\n").to_byte_array
  y := (file.read_content broker_path)
  return x == y
