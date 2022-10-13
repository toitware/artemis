// Copyright (C) 2022 Toitware ApS. All rights reserved.

import crypto.sha256
import host.file
import uuid

import encoding.base64
import encoding.ubjson
import encoding.json

import .sdk
import .cmds.provision show write_blob_to_file write_json_to_file write_ubjson_to_file
import .utils.patch_build show build_trivial_patch

import ..shared.mediator

/**
Manages devices that have an Artemis service running on them.
*/
class Artemis:
  mediator_/MediatorCli

  constructor .mediator_:

  close:
    // Do nothing for now.
    // The mediators are not created here and should be closed outside.

  /**
  Maps a device selector (name or id) to its id.
  */
  device_selector_to_id name/string -> string:
    return name

  app_install --device_id/string --app_name/string --application_path/string:
    program := CompiledProgram.application application_path
    id := program.id
    mediator_.upload_image --app_id=id --bits=32 program.image32
    mediator_.upload_image --app_id=id --bits=64 program.image64

    mediator_.device_update_config --device_id=device_id: | config/Map |
      print "$(%08d Time.monotonic_us): Installing app: $app_name"
      apps := config.get "apps" --if_absent=: {:}
      apps[app_name] = {"id": id, "random": (random 1000)}
      config["apps"] = apps
      config

  app_uninstall --device_id/string --app_name/string:
    mediator_.device_update_config --device_id=device_id: | config/Map |
      print "$(%08d Time.monotonic_us): Uninstalling app: $app_name"
      apps := config.get "apps"
      if apps: apps.remove app_name
      config

  config_set_max_offline --device_id/string --max_offline_seconds/int:
    mediator_.device_update_config --device_id=device_id: | config/Map |
      print "$(%08d Time.monotonic_us): Setting max-offline to $(Duration --s=max_offline_seconds)"
      if max_offline_seconds > 0:
        config["max-offline"] = max_offline_seconds
      else:
        config.remove "max-offline"
      config

  firmware_create
      --identity/Map
      --wifi/Map
      --device_id/string
      --firmware_path/string
      --output_path/string -> none:
    with_tmp_directory: | tmp/string |
      artemis_assets_path := "$tmp/artemis.assets"
      run_firmware_tool [
        "-e", firmware_path,
        "container", "extract",
        "-o", artemis_assets_path,
        "--part", "assets",
        "artemis"
      ]

      // TODO(kasper): Clean this up and provide a better error message.
      if not is_same_broker "broker" identity tmp artemis_assets_path:
        print "not the same broker"
        exit 1
      if not is_same_broker "artemis.broker" identity tmp artemis_assets_path:
        print "not the same artemis broker"
        exit 1

    device := identity["artemis.device"]
    mediator_.device_update_config --device_id=device_id: | config/Map |
      upgrade_to := compute_firmware_update_
          --device=device
          --wifi=wifi
          --envelope_path=firmware_path
          --upload=: // Do nothing.
      initial_firmware_config := base64.encode (ubjson.encode upgrade_to)
      print "firmware update = $initial_firmware_config"
      // TODO(kasper): We actually don't have to update the device configuration
      // stored in the online database unless we think it may contain garbage.
      config["firmware"] = initial_firmware_config
      config

  firmware_update --device_id/string --firmware_path/string -> none:
    mediator_.device_update_config --device_id=device_id: | config/Map |
      upgrade_from/Map := {:}
      existing := config.get "firmware"
      if existing: catch: upgrade_from = ubjson.decode (base64.decode existing)

      device := upgrade_from.get "artemis.device"
      if device:
        existing_id := device.get "device_id"
        if device_id != existing_id:
          print "Warning: Device id was wrong; expected $device_id but was $existing_id."
          device = null

      if not device:
        // Cannot proceed without an identity file.
        throw "Unclaimed device. Cannot proceed without an identity file."

      wifi := upgrade_from.get "wifi"
      if not wifi:
        // Device has no way to connect.
        print "Warning: Device has no way to connect."

      upgrade_to := compute_firmware_update_
          --device=device
          --wifi=wifi
          --envelope_path=firmware_path
          --upload=: | id/string parts/List |
            mediator_.upload_firmware --firmware_id=id parts

      updated := base64.encode (ubjson.encode upgrade_to)
      config["firmware"] = updated
      config

  compute_firmware_update_ --device/Map --wifi/Map --envelope_path/string [--upload] -> Map:
    unconfigured_parts := compute_firmware_update_parts_
        --envelope_path=envelope_path
        --upload=: // Do not upload.
    unconfigured_checksum := unconfigured_parts.remove_last

    config := {
      "artemis.device" : device,
      "wifi"           : wifi,
      "firmware"       : ubjson.encode unconfigured_parts,
    }

    configured_parts := compute_firmware_update_parts_
        --envelope_path=envelope_path
        --config=config
        --upload=: // Do not upload.
    configured_checksum := configured_parts.remove_last

    if false:
      unconfigured_parts.size.repeat: | index/int |
        print "--- $index ---"
        print "$unconfigured_parts[index]"
        print "$configured_parts[index]"

    return {
      "config"   : config,
      "checksum" : configured_checksum,
    }

  compute_firmware_update_parts_ --envelope_path/string --config/Map?=null [--upload] -> List:
    firmware/Map := extract_firmware_ envelope_path config
    firmware_bin/ByteArray := firmware["binary"]

    parts := []
    firmware["parts"].do: | entry/Map |
      from := entry["from"]
      to := entry["to"]

      part := firmware_bin[from..to]
      if entry["type"] == "config":
        parts.add { "from": from, "to": to, "type": "config" }
      else if entry["type"] == "checksum":
        parts.add part
      else:
        chunks := build_trivial_patch part
        sha := sha256.Sha256
        sha.add part
        hash := sha.get
        id/string := base64.encode hash
        upload.call id chunks
        parts.add { "from": from, "to": to, "hash": hash }
    return parts

extract_firmware_ envelope_path/string config/Map? -> Map:
  with_tmp_directory: | tmp/string |
    firmware_ubjson_path := "$tmp/firmware.ubjson"
    arguments := ["-e", envelope_path, "extract", "-o", firmware_ubjson_path, "--format=ubjson"]
    if config:
      config_path := "$tmp/config.json"
      write_blob_to_file config_path (ubjson.encode config)
      arguments += ["--config", config_path]
    run_firmware_tool arguments
    return ubjson.decode (file.read_content firmware_ubjson_path)
  unreachable

is_same_broker broker/string identity/Map tmp/string assets_path/string -> bool:
  broker_path := "$tmp/broker.json"
  run_assets_tool [
    "-e", assets_path,
    "get", "--format=tison",
    "-o", broker_path,
    "broker"
  ]
  // TODO(kasper): This is pretty crappy.
  x := ((json.stringify identity["broker"]) + "\n").to_byte_array
  y := (file.read_content broker_path)
  return x == y

same x/ByteArray y/ByteArray -> bool:
  if x.size != y.size: return false
  x.size.repeat:
    if x[it] != y[it]: return false
  return true
