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
import .cache show service_image_cache_key
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

  If $authenticated is true (the default), calls $BrokerCli.ensure_authenticated.
  */
  connected_broker_ --authenticated/bool=true -> BrokerCli:
    if not broker_:
      broker_ = BrokerCli broker_config_ config_
    if authenticated:
      broker_.ensure_authenticated:
        ui_.error "Not logged into broker"
        ui_.abort
    return broker_

  /**
  Returns a connected broker, using the $artemis_config_ to connect.

  If $authenticated is true (the default), calls $ArtemisServerCli.ensure_authenticated.
  */
  connected_artemis_server_ --authenticated/bool=true -> ArtemisServerCli:
    if not artemis_server_:
      connect_network_
      artemis_server_ = ArtemisServerCli network_ artemis_config_ config_
    if authenticated:
      artemis_server_.ensure_authenticated:
        ui_.error "Not logged into Artemis server"
        ui_.abort
    return artemis_server_

  /**
  Checks whether the given $sdk version and $service version is supported by
    the Artemis server.
  */
  check_is_supported_version_ --sdk/string?=null --service/string?=null:
    server := connected_artemis_server_
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
    server := connected_artemis_server_
    // Get the broker just after the server, in case it needs to authenticate.
    // We prefer to get an error message before we created a device on the
    // Artemis server.
    broker := connected_broker_

    device := server.create_device_in_organization
        --device_id=device_id
        --organization_id=organization_id
    assert: device.id == device_id
    hardware_id := device.hardware_id

    // Insert an initial event mostly for testing purposes.
    server.notify_created --hardware_id=hardware_id

    identity := {
      "device_id": device_id,
      "organization_id": organization_id,
      "hardware_id": hardware_id,
    }
    state := {
      "identity": identity,
    }
    broker.notify_created --device_id=device_id --state=state

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
      ui_.error "No WiFi connection configured."
      ui_.abort

    // Create the assets for the Artemis service.
    // TODO(florian): share this code with the identity creation code.
    der_certificates := {:}
    broker_json := server_config_to_service_json broker_config_ der_certificates
    artemis_json := server_config_to_service_json artemis_config_ der_certificates

    with_tmp_directory: | tmp_dir |
      // Store the containers in the envelope.
      device_specification.containers.do: | name/string container/Container |
        snapshot_path := "$tmp_dir/$(name).snapshot"
        container.build_snapshot
            --relative_to=device_specification.relative_to
            --sdk=sdk
            --output_path=snapshot_path
            --cache=cache_
        // TODO(florian): add support for assets.
        sdk.firmware_add_container name
            --envelope=output_path
            --program_path=snapshot_path
        apps := device_config.get "apps" --init=:{:}
        apps[name] = extract_id_from_snapshot snapshot_path
        ui_.info "Added container '$name' to envelope."

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
          --word_size=32  // TODO(florian): we should get the bits from the envelope.
          --sdk=sdk_version
          --service=service_version

      sdk.firmware_add_container "artemis" --envelope=output_path
          --assets=artemis_assets_path
          --program_path=artemis_service_image_path

    sdk.firmware_set_property "wifi-config" (json.stringify wifi_connection)
        --envelope=output_path

    // Also store the device specification. We don't really need it, but it
    // could be useful for debugging.
    encoded_specification := (json.encode device_specification.to_json).to_string
    sdk.firmware_set_property "device-specification" encoded_specification
        --envelope=output_path

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

    // For convenience save all snapshots in the user's cache.
    cache_snapshots --envelope=output_path --cache=cache_

  /**
  Updates the device $device_id with the firmware image at $envelope_path.
  */
  update --device_id/string --envelope_path/string:
    update_goal --device_id=device_id:
      | current_goal/Map? firmware_state/Map? current_state/Map? goal_state/Map? initial/Map? |
        if initial:
          // TODO(florian): Implement initial.
          ui_.error "Updating from initial state not yet implemented"
          ui_.abort

        known_encoded_firmwares := {}
        [current_goal, firmware_state, current_state, goal_state].do: | state/Map? |
          // The device might be running this firmware.
          if state: known_encoded_firmwares.add state["firmware"]

        if known_encoded_firmwares.is_empty:
          // Should not happen.
          ui_.error "No old firmware found for device '$device_id'."

        upgrade_from := []
        device/Map? := null
        known_encoded_firmwares.do: | encoded/string |
          old_firmware := Firmware.encoded encoded
          device = old_firmware.device_specific "artemis.device"
          if device["device_id"] != device_id:
            ui_.error "The device id of the firmware image ($device["device_id"]) does not match the given device id ($device_id)."
            ui_.abort
          upgrade_from.add old_firmware

        compute_updated_goal
            --device=device
            --upgrade_from=upgrade_from
            --envelope_path=envelope_path

  /**
  Computes the goal for the given $device, upgrading from the $upgrade_from
    firmwares to the firmware image at $envelope_path.

  The return goal state will instruct the device to download the firmware image
    and install it.
  */
  compute_updated_goal --device/Map --upgrade_from/List --envelope_path/string -> Map:
    sdk_version := Sdk.get_sdk_version_from --envelope=envelope_path
    sdk := get_sdk sdk_version --cache=cache_

    with_tmp_directory: | tmp_dir/string |
      assets_path := "$tmp_dir/assets"
      sdk.firmware_extract_container
          --name="artemis"  // TODO(florian): use constants for hard-coded names.
          --assets
          --envelope_path=envelope_path
          --output_path=assets_path

      config_asset := sdk.assets_extract
          --name="device-config"
          --assets_path=assets_path

      new_config := json.decode config_asset

      upgrade_to := compute_device_specific_firmware
          --envelope_path=envelope_path
          --device=device

      // Compute the patches and upload them.
      ui_.info "Computing and uploading patches."
      upgrade_from.do: | old_firmware/Firmware |
        patches := upgrade_to.patches old_firmware
        patches.do: upload_ it

      new_config["firmware"] = upgrade_to.encoded
      return new_config
    unreachable

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
    return compute_device_specific_data
        --envelope_path=envelope_path
        --identity_path=identity_path
        --cache=cache_
        --ui=ui_

  /**
  Variant of $(compute_device_specific_data --envelope_path --identity_path).
  */
  static compute_device_specific_data -> ByteArray
      --envelope_path/string
      --identity_path/string
      --cache/cache.Cache
      --ui/Ui:
    // Use the SDK from the envelope.
    sdk_version := Sdk.get_sdk_version_from --envelope=envelope_path
    sdk := get_sdk sdk_version --cache=cache

    // Extract the device ID from the identity file.
    // TODO(florian): abstract the identity management.
    identity_raw := file.read_content identity_path

    identity := ubjson.decode (base64.decode identity_raw)


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
        ui.warning "The identity file and the Artemis assets in the envelope don't use the same broker"
      if not is_same_broker "artemis.broker" identity tmp artemis_assets_path sdk:
        ui.warning "The identity file and the Artemis assets in the envelope don't use the same Artemis server"

    device := identity["artemis.device"]

    // We don't really need the full firmware and just the device-specific data,
    // but by cooking the firmware we get the checksums correct.
    firmware := compute_device_specific_firmware
        --envelope_path=envelope_path
        --device=device
        --cache=cache
        --ui=ui

    return firmware.device_specific_data

  /**
  Creates a device-specific firmware image from the given envelope.
  */
  compute_device_specific_firmware -> Firmware
      --envelope_path/string
      --device/Map:
    return compute_device_specific_firmware
        --envelope_path=envelope_path
        --device=device
        --cache=cache_
        --ui=ui_

  /**
  Variant of $(compute_device_specific_firmware --envelope_path --device).
  */
  static compute_device_specific_firmware -> Firmware
      --envelope_path/string
      --device/Map
      --cache/cache.Cache
      --ui/Ui:

    // Use the SDK from the envelope.
    sdk_version := Sdk.get_sdk_version_from --envelope=envelope_path
    sdk := get_sdk sdk_version --cache=cache

    // Extract the WiFi credentials from the envelope.
    encoded_wifi_config := sdk.firmware_get_property "wifi-config" --envelope=envelope_path
    wifi_config := json.parse encoded_wifi_config
    wifi_ssid := wifi_config["ssid"]
    wifi_password := wifi_config["password"]

    device_id := device["device_id"]

    // Cook the firmware.
    return Firmware
        --envelope_path=envelope_path
        --device=device
        --cache=cache
        --wifi={
          // TODO(florian): replace the hardcoded key constants.
          "wifi.ssid": wifi_ssid,
          "wifi.password": wifi_password,
        }

  /**
  Gets the Artemis service image for the given $sdk and $service versions.

  Returns a path to the cached image.
  */
  get_service_image_path_ --sdk/string --service/string --word_size/int -> string:
    if word_size != 32 and word_size != 64: throw "INVALID_ARGUMENT"
    service_key := service_image_cache_key --service_version=service --sdk_version=sdk
    return cache_.get_file_path service_key: | store/cache.FileStore |
      server := connected_artemis_server_ --no-authenticated
      entry := server.list_sdk_service_versions --sdk_version=sdk --service_version=service
      if entry.is_empty:
        ui_.error "Unsupported Artemis/SDK versions."
        ui_.abort
      image_name := entry.first["image"]
      service_image_bytes := server.download_service_image image_name
      ar_reader := ar.ArReader.from_bytes service_image_bytes
      ar_file := ar_reader.find "service-$(word_size).img"
      store.save ar_file.content

  /**
  Updates the goal state of the device with the given $device_id.

  The block is called with 5 arguments:
  - the current goal state: the configuration that the broker currently sends
    to the device. May be null if no goal state was set yet.
  - the firmware state: the configuration of the device's firmware when it
    last reported its state. May be null if the device hasn't reported its
    state yet.
  - the current state: the configuration of the device when it last reported
    its state. If the "firmware" entry is not the same as the one in the
    firmware state, then the device has updated its firmware but has not
    yet rebooted. May be null if the device hasn't reported its state yet, or
    if the state is the same as for the firmware.
  - the known goal state: the configuration the device last reported as its goal.
    This might be different from the actual goal state if the device either
    didn't yet receive the new goal state, or if the device didn't report its
    current state yet. May be null if the device hasn't reported its state yet,
    or if the state is the same as for the current state.
  - the initial state: the initial status (as stored by $BrokerCli.notify_created).
    Null, if the device has reported its state.

  The $block should return a new configuration which replaces the actual goal state.

  The $block is allowed to modify the given configuration but is still required
    to return it.
  */
  update_goal --device_id/string [block] -> none:
    connected_broker_.device_update_goal --device_id=device_id: | current_goal/Map? state/Map? |
      firmware_state/Map? := state and state.get "firmware-state"
      current_state/Map? := state and state.get "current-state"
      known_goal/Map? := state and state.get "goal-state"

      initial_state := firmware_state ? null : state

      block.call firmware_state current_state known_goal current_goal initial_state

  image_cache_id_ id/string -> string:
    return "$broker_config_.name/images/$id"

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
        connected_broker_.upload_image --app_id=id --word_size=32 program.image32
        file.write_content program.image32 --path="$tmp_dir/image32.bin"
        connected_broker_.upload_image --app_id=id --word_size=64 program.image64
        file.write_content program.image64 --path="$tmp_dir/image64.bin"
        store.move tmp_dir

    update_goal --device_id=device_id: | current_goal/Map? firmware_state/Map? |
      if not current_goal and not firmware_state: throw "No known firmware information for device."
      new_goal := current_goal or firmware_state
      log.info "$(%08d Time.monotonic_us): Installing app: $app_name"
      apps := new_goal.get "apps" --if_absent=: {:}
      apps[app_name] = id
      new_goal["apps"] = apps
      new_goal

  app_uninstall --device_id/string --app_name/string:
    update_goal --device_id=device_id: | current_goal/Map? firmware_state/Map? |
      if not current_goal and not firmware_state: throw "No known firmware information for device."
      new_goal := current_goal or firmware_state
      log.info "$(%08d Time.monotonic_us): Uninstalling app: $app_name"
      apps := new_goal.get "apps"
      if apps: apps.remove app_name
      new_goal

  config_set_max_offline --device_id/string --max_offline_seconds/int:
    update_goal --device_id=device_id: | current_goal/Map? firmware_state/Map? |
      if not current_goal and not firmware_state: throw "No known firmware information for device."
      new_goal := current_goal or firmware_state
      log.info "$(%08d Time.monotonic_us): Setting max-offline to $(Duration --s=max_offline_seconds)"
      if max_offline_seconds > 0:
        new_goal["max-offline"] = max_offline_seconds
      else:
        new_goal.remove "max-offline"
      new_goal

  /**
  Computes patches and uploads them to the broker.
  */
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
