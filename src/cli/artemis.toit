// Copyright (C) 2022 Toitware ApS. All rights reserved.

import crypto.sha256
import host.file
import uuid

import encoding.base64
import encoding.ubjson
import encoding.json

import .sdk
import .cmds.provision show write_blob_to_file write_json_to_file
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
    device := identity["artemis.device"]
    with_tmp_directory: | tmp/string |
      initial_firmware_config/string? := null
      mediator_.device_update_config --device_id=device_id: | config/Map |
        upgrade_to := compute_firmware_update_
            --device=device
            --wifi=wifi
            --envelope_path=firmware_path
            --upload=: // Do nothing.
        initial_firmware_config = base64.encode (ubjson.encode upgrade_to)
        // TODO(kasper): We actually don't have to update the device configuration
        // stored in the online database unless we think it may contain garbage.
        config["firmware"] = initial_firmware_config
        config

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

      write_json_to_file "$tmp/device.json" device
      run_assets_tool [
        "-e", artemis_assets_path,
        "add", "--format=tison",
        "artemis.device", "$tmp/device.json"
      ]

      write_blob_to_file "$tmp/firmware.config" initial_firmware_config
      run_assets_tool [
        "-e", artemis_assets_path,
        "add",
        "artemis.firmware.initial", "$tmp/firmware.config"
      ]

      artemis_image_path := "$tmp/artemis.image"
      run_firmware_tool [
        "-e", firmware_path,
        "container", "extract",
        "-o", artemis_image_path,
        "--part", "image",
        "artemis"
      ]

      firmware_envelope_path := "$tmp/firmware.envelope"
      run_firmware_tool [
        "-e", firmware_path,
        "container", "install",
        "-o", firmware_envelope_path,
        "--assets", artemis_assets_path,
        "artemis",
        artemis_image_path
      ]

      run_firmware_tool [
        "-e", firmware_envelope_path,
        "property", "set",
        "-o", output_path,
        "wifi", (json.stringify wifi)
      ]

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
    firmware_bin/ByteArray := extract_firmware_bin_ envelope_path

    parts/List := build_trivial_patch firmware_bin
    sha := sha256.Sha256
    sha.add firmware_bin
    id/string := base64.encode sha.get
    upload.call id parts

    // TODO(kasper): This should include the uuid, so we can compile apps that fit later.
    // How do we get from uuid to Toit SDK version? Is that something we need to support?
    // The uuid seems strictly better because it takes the full base image into account.

    return {
      "parts": [ id ],
      "artemis.device": device,
      "wifi": wifi,
    }

extract_firmware_bin_ envelope_path/string -> ByteArray:
  with_tmp_directory: | tmp/string |
    firmware_bin_path := "$tmp/firmware.bin"
    run_firmware_tool ["-e", envelope_path, "extract", "-o", firmware_bin_path, "--firmware.bin"]
    return file.read_content firmware_bin_path
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
