// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ar
import crypto.sha256
import host.file
import bytes
import log
import net
import writer
import uuid

import encoding.base64
import encoding.ubjson
import encoding.json

import .cache as cache
import .config
import .device_specification

import .utils
import .utils.patch_build show build_diff_patch build_trivial_patch
import ..shared.utils.patch show Patcher PatchObserver

import .artemis_servers.artemis_server
import .brokers.broker
import .firmware
import .program
import .sdk
import .ui
import .server_config

/**
Manages devices that have an Artemis service running on them.
*/
class Artemis:
  broker_/BrokerCli? := null
  artemis_server_/ArtemisServerCli? := null
  network_/net.Interface? := null

  config_/Config
  cache_/cache.Cache
  ui_/Ui
  broker_config_/ServerConfig
  artemis_config_/ServerConfig

  constructor --config/Config --cache/cache.Cache --ui/Ui
      --broker_config/ServerConfig
      --artemis_config/ServerConfig:
    config_ = config
    cache_ = cache
    ui_ = ui
    broker_config_ = broker_config
    artemis_config_ = artemis_config

  /**
  Closes the manager.

  If the manager opened any connections, closes them as well.
  */
  close:
    if broker_: broker_.close
    if artemis_server_: artemis_server_.close
    if network_: network_.close
    broker_ = null
    artemis_server_ = null
    network_ = null

  /** Opens the network. */
  connect_network_:
    if network_: return
    network_ = net.open

  /**
  Returns a connected broker, using the $broker_config_ to connect.

  If $authenticated is true, calls $BrokerCli.ensure_authenticated.
  */
  connected_broker_ --authenticated/bool=false -> BrokerCli:
    if not broker_:
      broker_ = BrokerCli broker_config_ config_
    if authenticated:
      broker_.ensure_authenticated:
        ui_.error "Not logged in"
        ui_.abort
    return broker_

  /**
  Returns a connected broker, using the $artemis_config_ to connect.

  If $authenticated is true, calls $ArtemisServerCli.ensure_authenticated.
  */
  connected_artemis_server_ --authenticated/bool=false -> ArtemisServerCli:
    if not artemis_server_:
      connect_network_
      artemis_server_ = ArtemisServerCli network_ artemis_config_ config_
    if authenticated:
      artemis_server_.ensure_authenticated:
        ui_.error "Not logged in"
        ui_.abort
    return artemis_server_

  /**
  Checks whether the given $sdk version and $service version is supported by
    the Artemis server.
  */
  check_is_supported_version_ --sdk/string?=null --service/string?=null:
    server := connected_artemis_server_ --authenticated
    versions := server.list_sdk_service_versions
        --sdk_version=sdk
        --service_version=service
    if versions.is_empty:
      ui_.error "Unsupported Artemis/SDK versions."
      ui_.abort

  /**
  Provisions a device.

  Contacts the Artemis server and creates a new device entry with the
    given $device_id (used as "alias" on the server side) in the
    organization with the given $organization_id.

  Writes the identity file to $out_path.
  */
  provision --device_id/string --out_path/string --organization_id/string:
    server := connected_artemis_server_ --authenticated

    device := server.create_device_in_organization
        --device_id=device_id
        --organization_id=organization_id
    assert: device.id == device_id
    hardware_id := device.hardware_id

    // Insert an initial event mostly for testing purposes.
    server.notify_created --hardware_id=hardware_id

    write_identity_file
        --out_path=out_path
        --device_id=device_id
        --organization_id=organization_id
        --hardware_id=hardware_id

  /**
  Writes an identity file.

  This file is used to build a device image and needs to be given to
    $compute_device_specific_data.
  */
  write_identity_file -> none
      --out_path/string
      --device_id/string
      --organization_id/string
      --hardware_id/string:
    // A map from id to DER certificates.
    der_certificates := {:}

    broker_json := server_config_to_service_json broker_config_ der_certificates
    artemis_json := server_config_to_service_json artemis_config_ der_certificates

    identity ::= {
      "artemis.device": {
        "device_id"       : device_id,
        "organization_id" : organization_id,
        "hardware_id"     : hardware_id,
      },
      "artemis.broker": artemis_json,
      "broker": broker_json,
    }

    // Add the necessary certificates to the identity.
    der_certificates.do: | name/string content/ByteArray |
      // The 'server_config_to_service_json' function puts the certificates
      // into their own namespace.
      assert: name.starts_with "certificate-"
      identity[name] = content

    write_base64_ubjson_to_file out_path identity

  /**
  Customizes a generic Toit envelope with the given $device_specification.
    Also installs the Artemis service.

  The image is ready to be flashed together with the identity file.
  */
  customize_envelope
      --device_specification/DeviceSpecification
      --output_path/string:
    sdk_version := device_specification.sdk_version
    service_version := device_specification.artemis_version
    check_is_supported_version_ --sdk=sdk_version --service=service_version

    sdk := get_sdk sdk_version --cache=cache_
    cached_envelope_path := get_envelope sdk_version --cache=cache_

    copy_file --source=cached_envelope_path --target=output_path

    device_config := {
      "max-offline": device_specification.max_offline_seconds,
      "sdk-version": sdk_version,
    }

    wifi_connection/Map? := null

    connections := device_specification.connections
    connections.do: | connection/ConnectionInfo |
      if connection.type == "wifi":
        wifi := connection as WifiConnectionInfo
        wifi_connection = {
          "ssid": wifi.ssid,
          "password": wifi.password or "",
        }
        // TODO(florian): should device configurations be stored in
        // the Artemis asset?
        device_config["wifi"] = wifi_connection
      else:
        ui_.error "Unsupported connection type: $connection.type"
        ui_.abort

    if not wifi_connection:
      ui_.error "No wifi connection configured."
      ui_.abort

    // Create the assets for the Artemis service.
    // TODO(florian): share this code with the identity creation code.
    der_certificates := {:}
    broker_json := server_config_to_service_json broker_config_ der_certificates
    artemis_json := server_config_to_service_json artemis_config_ der_certificates

    with_tmp_directory: | tmp_dir |
      artemis_assets := {
        // TODO(florian): share the keys of the assets with the Artemis service.
        "broker": {
          "format": "tison",
          "json": broker_json,
        },
        "artemis.broker": {
          "format": "tison",
          "json": artemis_json,
        },
      }
      der_certificates.do: | name/string value/ByteArray |
        // The 'server_config_to_service_json' function puts the certificates
        // into their own namespace.
        assert: name.starts_with "certificate-"
        artemis_assets[name] = {
          "format": "binary",
          "blob": value,
        }

      artemis_assets["device-config"] = {
        "format": "ubjson",
        "json": device_config,
      }

      artemis_assets_path := "$tmp_dir/artemis.assets"
      sdk.assets_create --output_path=artemis_assets_path artemis_assets

      // Get the prebuilt Artemis service.
      artemis_service_image_path := get_service_image_path_
          --bits=32  // TODO(florian): we should get the bits from the envelope.
          --sdk=sdk_version
          --service=service_version

      sdk.firmware_add_container "artemis" --envelope=output_path
          --assets=artemis_assets_path
          --image=artemis_service_image_path

      // Store the apps in the envelope.
      device_specification.apps.do: | name/string app/Application |
        snapshot_app := to_snapshot_app_ app --tmp_dir=tmp_dir --sdk=sdk
        image_path := "$tmp_dir/$(name).image"
        // TODO(florian): we should get the bits from the envelope.
        sdk.compile_snapshot_to_image
            --bits=32
            --snapshot_path=snapshot_app.snapshot_path
            --out=image_path
        // TODO(florian): add support for assets.
        sdk.firmware_add_container name --envelope=output_path --image=image_path
        ui_.info "Added app '$name' to envelope."

    sdk.firmware_set_property "wifi-config" (json.stringify wifi_connection)
        --envelope=output_path

    // Also store the device specification. We don't really need it, but it
    // could be useful for debugging.
    encoded_specification := (json.encode device_specification.to_json).to_string
    sdk.firmware_set_property "device-specification" encoded_specification
        --envelope=output_path

    // TODO(florian): envelopes should already know which SDK version they come
    // from.
    // Explicitly store the SDK version in the firmware image.
    Sdk.store_sdk_version_in --envelope=output_path sdk_version

    // Finally, make it unique. The system uuid will have to be used when compiling
    // code for the device in the future. This will prove that you know which versions
    // went into the firmware image.
    system_uuid ::= uuid.uuid5 "system.uuid" "$(random 1_000_000)-$Time.now-$Time.monotonic_us"
    sdk.firmware_set_property "uuid" system_uuid.stringify --envelope=output_path

    // Upload the trivial patches.
    // Once the firmware is used in an updating process (either to or from it), we
    // need it. In that case we use it to compute binary diffs. It can also be
    // used directly from the devices to download the firmware directly.
    firmware_content := FirmwareContent.from_envelope output_path --cache=cache_
    firmware_content.trivial_patches.do: upload_ it

  /**
  Computes the device-specific data of the given envelope.

  Combines the envelope ($envelope_path) and identity ($identity_path) into a
    single firmware image and computes the configuration which depends on the
    checksums of the individual parts.

  In this context the configuration consists of the checksums of the individual
    parts of the firmware image, combined with the configuration that was
    stored in the envelope.
  */
  compute_device_specific_data --envelope_path/string --identity_path/string -> ByteArray:
    // Use the SDK from the envelope.
    sdk_version := Sdk.get_sdk_version_from --envelope=envelope_path
    sdk := get_sdk sdk_version --cache=cache_

    // Extract the WiFi credentials from the envelope.
    encoded_wifi_config := sdk.firmware_get_property "wifi-config" --envelope=envelope_path
    wifi_config := json.parse encoded_wifi_config
    wifi_ssid := wifi_config["ssid"]
    wifi_password := wifi_config["password"]

    // Extract the device ID from the identity file.
    // TODO(florian): abstract the identity management.
    identity_raw := file.read_content identity_path

    identity := ubjson.decode (base64.decode identity_raw)
    device := identity["artemis.device"]
    device_id := device["device_id"]

    // Since we already have the identity content, check that the artemis server
    // is the same.
    // This is primarily a sanity check, and we might remove the broker from the
    // identity file in the future. Since users are not supposed to be able to
    // change the Artemis server, there wouldn't be much left of the check.
    // TODO(florian): remove this check?
    with_tmp_directory: | tmp/string |
      artemis_assets_path := "$tmp/artemis.assets"
      sdk.run_firmware_tool [
        "-e", envelope_path,
        "container", "extract",
        "-o", artemis_assets_path,
        "--part", "assets",
        "artemis"
      ]

      if not is_same_broker "artemis.broker" identity tmp artemis_assets_path sdk:
        ui_.warning "The identity file and the Artemis assets in the envelope don't use the same broker"
      if not is_same_broker "artemis.broker" identity tmp artemis_assets_path sdk:
        ui_.warning "The identity file and the Artemis assets in the envelope don't use the same Artemis server"

    // Cook the firmware.
    // We don't actually need the full firmware for flashing, but we need to build it to
    // compute the checksums.
    firmware := Firmware
        --envelope_path=envelope_path
        --device=device
        --cache=cache_
        --wifi={
          // TODO(florian): replace the hardcoded key constants.
          "wifi.ssid": wifi_ssid,
          "wifi.password": wifi_password,
        }

    return firmware.device_specific_data

  /**
  Gets the Artemis service image for the given $sdk and $service versions.

  Returns a path to the cached image.
  */
  get_service_image_path_ --sdk/string --service/string --bits/int -> string:
    if bits != 32 and bits != 64: throw "INVALID_ARGUMENT"
    service_key := "service/$service/$(sdk).image"
    return cache_.get_file_path service_key: | store/cache.FileStore |
      server := connected_artemis_server_
      entry := server.list_sdk_service_versions --sdk_version=sdk --service_version=service
      if entry.is_empty:
        ui_.error "Unsupported Artemis/SDK versions."
        ui_.abort
      image_name := entry.first["image"]
      service_image_bytes := server.download_service_image image_name
      ar_reader := ar.ArReader.from_bytes service_image_bytes
      ar_file := ar_reader.find "service-$(bits).img"
      store.save ar_file.content

  /**
  Maps a device selector (name or id) to its id.
  */
  device_selector_to_id name/string -> string:
    return name

  image_cache_id_ id/string -> string:
    return "$broker_.id/images/$id"

  app_install --device_id/string --app_name/string --application_path/string:
    // TODO(florian): get the sdk from the device.
    sdk := Sdk
    program := CompiledProgram.application application_path --sdk=sdk
    id := program.id
    cache_id := image_cache_id_ id
    cache_.get_directory_path cache_id: | store/cache.DirectoryStore |
      store.with_tmp_directory: | tmp_dir |
        // TODO(florian): do we want to rely on the cache, or should we
        // do a check to see if the files are really uploaded?
        connected_broker_.upload_image --app_id=id --bits=32 program.image32
        file.write_content program.image32 --path="$tmp_dir/image32.bin"
        connected_broker_.upload_image --app_id=id --bits=64 program.image64
        file.write_content program.image64 --path="$tmp_dir/image64.bin"
        store.move tmp_dir

    connected_broker_.device_update_config --device_id=device_id: | config/Map |
      log.info "$(%08d Time.monotonic_us): Installing app: $app_name"
      apps := config.get "apps" --if_absent=: {:}
      apps[app_name] = {"id": id, "random": (random 1000)}
      config["apps"] = apps
      config

  app_uninstall --device_id/string --app_name/string:
    connected_broker_.device_update_config --device_id=device_id: | config/Map |
      log.info "$(%08d Time.monotonic_us): Uninstalling app: $app_name"
      apps := config.get "apps"
      if apps: apps.remove app_name
      config

  config_set_max_offline --device_id/string --max_offline_seconds/int:
    connected_broker_.device_update_config --device_id=device_id: | config/Map |
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
    // TODO(florian): get the sdk as argument.
    sdk := Sdk
    with_tmp_directory: | tmp/string |
      artemis_assets_path := "$tmp/artemis.assets"
      sdk.run_firmware_tool [
        "-e", firmware_path,
        "container", "extract",
        "-o", artemis_assets_path,
        "--part", "assets",
        "artemis"
      ]

      // TODO(kasper): Clean this up and provide a better error message.
      if not is_same_broker "broker" identity tmp artemis_assets_path sdk:
        ui.error "not the same broker"
        ui.abort
      if not is_same_broker "artemis.broker" identity tmp artemis_assets_path sdk:
        ui.error "not the same artemis broker"
        ui.abort

    firmware/Firmware? := null
    connected_broker_.device_update_config --device_id=device_id: | config/Map |
      device := identity["artemis.device"]
      upgrade_to := Firmware
          --device=device
          --wifi=wifi
          --envelope_path=firmware_path
          --cache=cache_

      patches := upgrade_to.patches null
      patches.do: upload_ it
      firmware = upgrade_to

      // TODO(kasper): We actually don't have to update the device configuration
      // stored in the online database unless we think it may contain garbage.
      config["firmware"] = upgrade_to.encoded
      config

    return firmware

  firmware_update --device_id/string --firmware_path/string --ui/Ui -> none:
    connected_broker_.device_update_config --device_id=device_id: | config/Map |
      upgrade_from/Firmware? := null
      existing := config.get "firmware"
      if existing: catch: upgrade_from = Firmware.encoded existing

      device := null
      if upgrade_from: device = upgrade_from.device_specific "artemis.device"
      if device:
        existing_id := device.get "device_id"
        if device_id != existing_id:
          ui.error "Device id was wrong; expected $device_id but was $existing_id."
          device = null

      if not device:
        // Cannot proceed without an identity file.
        throw "Unclaimed device. Cannot proceed without an identity file."

      wifi := null
      if upgrade_from: wifi = upgrade_from.device_specific "wifi"
      if not wifi:
        // Device has no way to connect.
        ui.error "Device has no way to connect."

      upgrade_to := Firmware
          --device=device
          --wifi=wifi
          --envelope_path=firmware_path
          --cache=cache_

      patches := upgrade_to.patches upgrade_from
      patches.do: upload_ it
      config["firmware"] = upgrade_to.encoded
      config

  upload_ patch/FirmwarePatch -> none:
    trivial_id := id_ --to=patch.to_
    cache_key := "$connected_broker_.id/patches/$trivial_id"
    // Unless it is already cached, always create/upload the trivial one.
    cache_.get cache_key: | store/cache.FileStore |
      trivial := build_trivial_patch patch.bits_
      connected_broker_.upload_firmware --firmware_id=trivial_id trivial
      store.save_via_writer: | writer/writer.Writer |
        trivial.do: writer.write it

    if not patch.from_: return

    // Attempt to fetch the old trivial patch and use it to construct
    // the old bits so we can compute a diff from them.
    old_id := id_ --to=patch.from_
    cache_key = "$connected_broker_.id/patches/$old_id"
    trivial_old := cache_.get cache_key: | store/cache.FileStore |
      downloaded := null
      catch: downloaded = connected_broker_.download_firmware --id=old_id
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
    cache_key = "$connected_broker_.id/patches/$diff_id"
    cache_.get cache_key: | store/cache.FileStore |
      // Build the diff and verify that we can apply it and get the
      // correct hash out before uploading it.
      diff := build_diff_patch old patch.bits_
      if patch.to_ != (compute_applied_hash_ diff old): return
      connected_broker_.upload_firmware --firmware_id=diff_id diff
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

to_snapshot_app_ app/Application --tmp_dir/string --sdk/Sdk -> ApplicationSnapshot:
  if app.type == "snapshot":
    // TODO(florian): verify that the snapshot's SDK is the same as the one we are using.
    return app as ApplicationSnapshot
  if app.type == "path":
    entry_point := (app as ApplicationPath).entrypoint
    snapshot_path := "$tmp_dir/snapshot"
    sdk.compile_to_snapshot entry_point --out=snapshot_path
    return ApplicationSnapshot --snapshot_path=snapshot_path

  throw "Unknown application type: $app.type"

