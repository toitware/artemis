// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ar
import crypto.sha256
import host.file
import host.os
import bytes
import log
import net
import writer
import uuid

import encoding.base64
import encoding.ubjson
import encoding.json

import .cache as cache
import .cache show service-image-cache-key application-image-cache-key
import .config
import .device
import .pod
import .pod-specification

import .utils
import .utils.patch-build show build-diff-patch build-trivial-patch
import ..shared.utils.patch show Patcher PatchObserver

import .artemis-servers.artemis-server
import .brokers.broker
import .firmware
import .program
import .sdk
import .ui
import .server-config

/**
Manages devices that have an Artemis service running on them.
*/
class Artemis:
  broker_/BrokerCli? := null
  artemis-server_/ArtemisServerCli? := null
  network_/net.Interface? := null

  config_/Config
  cache_/cache.Cache
  ui_/Ui
  broker-config_/ServerConfig
  artemis-config_/ServerConfig
  tmp-directory/string

  constructor --config/Config --cache/cache.Cache --ui/Ui
      --.tmp-directory
      --broker-config/ServerConfig
      --artemis-config/ServerConfig:
    config_ = config
    cache_ = cache
    ui_ = ui
    broker-config_ = broker-config
    artemis-config_ = artemis-config

  /**
  Closes the manager.

  If the manager opened any connections, closes them as well.
  */
  close:
    if broker_: broker_.close
    if artemis-server_: artemis-server_.close
    if network_: network_.close
    broker_ = null
    artemis-server_ = null
    network_ = null

  /** Opens the network. */
  connect-network_:
    if network_: return
    network_ = net.open

  /**
  Returns a connected broker, using the $broker-config_ to connect.

  If $authenticated is true (the default), calls $BrokerCli.ensure-authenticated.
  */
  connected-broker --authenticated/bool=true -> BrokerCli:
    if not broker_:
      broker_ = BrokerCli broker-config_ config_
    if authenticated:
      broker_.ensure-authenticated: | error-message |
        ui_.abort "$error-message (broker)."
    return broker_

  /**
  Returns a connected broker, using the $artemis-config_ to connect.

  If $authenticated is true (the default), calls $ArtemisServerCli.ensure-authenticated.
  */
  connected-artemis-server --authenticated/bool=true -> ArtemisServerCli:
    if not artemis-server_:
      connect-network_
      artemis-server_ = ArtemisServerCli network_ artemis-config_ config_
    if authenticated:
      artemis-server_.ensure-authenticated: | error-message |
        ui_.abort "$error-message (artemis)."
    return artemis-server_

  /**
  Checks whether the given $sdk version and $service version is supported by
    the Artemis server.
  */
  check-is-supported-version_ --organization-id/uuid.Uuid --sdk/string?=null --service/string?=null:
    server := connected-artemis-server
    versions := server.list-sdk-service-versions
        --organization-id=organization-id
        --sdk-version=sdk
        --service-version=service
    if versions.is-empty:
      ui_.abort "Unsupported Artemis/SDK versions ($service/$sdk)."

  /**
  Provisions a device.

  Contacts the Artemis server and creates a new device entry with the
    given $device-id (used as "alias" on the server side) in the
    organization with the given $organization-id.

  Writes the identity file to $out-path.
  */
  provision --device-id/uuid.Uuid? --out-path/string --organization-id/uuid.Uuid:
    server := connected-artemis-server
    // Get the broker just after the server, in case it needs to authenticate.
    // We prefer to get an error message before we created a device on the
    // Artemis server.
    broker := connected-broker

    device := server.create-device-in-organization
        --device-id=device-id
        --organization-id=organization-id
    assert: device.id == device-id
    hardware-id := device.hardware-id

    // Insert an initial event mostly for testing purposes.
    server.notify-created --hardware-id=hardware-id

    identity := {
      "device_id": "$device-id",
      "organization_id": "$organization-id",
      "hardware_id": "$hardware-id",
    }
    state := {
      "identity": identity,
    }
    broker.notify-created --device-id=device-id --state=state

    write-identity-file
        --out-path=out-path
        --device-id=device-id
        --organization-id=organization-id
        --hardware-id=hardware-id

  /**
  Writes an identity file.

  This file is used to build a device image and needs to be given to
    $compute-device-specific-data.
  */
  write-identity-file -> none
      --out-path/string
      --device-id/uuid.Uuid
      --organization-id/uuid.Uuid
      --hardware-id/uuid.Uuid:
    // A map from id to DER certificates.
    der-certificates := {:}

    broker-json := server-config-to-service-json broker-config_ der-certificates
    artemis-json := server-config-to-service-json artemis-config_ der-certificates

    identity ::= {
      "artemis.device": {
        "device_id"       : "$device-id",
        "organization_id" : "$organization-id",
        "hardware_id"     : "$hardware-id",
      },
      "artemis.broker": artemis-json,
      "broker": broker-json,
    }

    // Add the necessary certificates to the identity.
    der-certificates.do: | name/string content/ByteArray |
      // The 'server_config_to_service_json' function puts the certificates
      // into their own namespace.
      assert: name.starts-with "certificate-"
      identity[name] = content

    write-base64-ubjson-to-file out-path identity

  /**
  Customizes a generic Toit envelope with the given $specification.
    Also installs the Artemis service.

  The image is ready to be flashed together with the identity file.
  */
  customize-envelope
      --organization-id/uuid.Uuid
      --specification/PodSpecification
      --output-path/string:
    service-version := specification.artemis-version
    sdk-version := specification.sdk-version

    checked := false
    // We try to check the sdk and service versions as soon as possible to
    // avoid downloading expensive assets.
    check-sdk-service-version := :
      if not checked and sdk-version:
        check-is-supported-version_
            --organization-id=organization-id
            --sdk=sdk-version
            --service=service-version
        checked = true

    check-sdk-service-version.call

    envelope-path := get-envelope
        --specification=specification
        --cache=cache_

    // Extract the sdk version from the envelope.
    envelope := file.read-content envelope-path
    envelope-sdk-version := Sdk.get-sdk-version-from --envelope=envelope
    if sdk-version:
      if sdk-version != envelope-sdk-version:
        if not (is-dev-setup and os.env.get "DEV_TOIT_REPO_PATH"):
          ui_.abort "The envelope uses SDK version '$envelope-sdk-version', but '$sdk-version' was requested."
    else:
      sdk-version = envelope-sdk-version
      check-sdk-service-version.call

    sdk := get-sdk sdk-version --cache=cache_

    copy-file --source=envelope-path --target=output-path

    device-config := {
      "sdk-version": sdk-version,
    }

    // Add the max-offline setting if is non-zero. The device service
    // handles the absence of the max-offline setting differently, so
    // we cannot just add zero seconds to the config. This matches what
    // we do in $config_set_max_offline.
    max-offline-seconds := specification.max-offline-seconds
    if max-offline-seconds > 0: device-config["max-offline"] = max-offline-seconds

    if specification.connections.is-empty:
      ui_.abort "No network connections configured."
    connections := specification.connections.map: | connection/ConnectionInfo |
      connection.to-json
    device-config["connections"] = connections

    // Create the assets for the Artemis service.
    // TODO(florian): share this code with the identity creation code.
    der-certificates := {:}
    broker-json := server-config-to-service-json broker-config_ der-certificates
    artemis-json := server-config-to-service-json artemis-config_ der-certificates

    with-tmp-directory: | tmp-dir |
      // Store the containers in the envelope.
      specification.containers.do: | name/string container/Container |
        snapshot-path := "$tmp-dir/$(name).snapshot"
        container.build-snapshot
            --relative-to=specification.relative-to
            --sdk=sdk
            --output-path=snapshot-path
            --cache=cache_
            --ui=ui_

        // Build the assets from the defines (if any).
        assets-path/string? := null
        if container.defines:
          assets-path = "$tmp-dir/$(name).assets"
          assets := {
            "artemis.defines": {
              "format": "tison",
              "json": container.defines
            }
          }
          sdk.assets-create --output-path=assets-path assets

        sdk.firmware-add-container name
            --envelope=output-path
            --assets=assets-path
            --program-path=snapshot-path
            --trigger="none"

        // TODO(kasper): Avoid computing the image id here. We should
        // be able to get it from the firmware tool.
        sha := sha256.Sha256
        snapshot-uuid-string := extract-id-from-snapshot snapshot-path
        sha.add (uuid.parse snapshot-uuid-string).to-byte-array
        if assets-path:
          sha.add (file.read-content assets-path)
        id := uuid.Uuid sha.get[..uuid.SIZE]

        triggers := container.triggers
        if not container.is-critical and not triggers:
          // Non-critical containers default to having a boot trigger.
          triggers = [BootTrigger]
        apps := device-config.get "apps" --init=:{:}
        apps[name] = build-container-description_
            --id=id
            --arguments=container.arguments
            --background=container.is-background
            --critical=container.is-critical
            --runlevel=container.runlevel
            --triggers=triggers
        ui_.info "Added container '$name' to envelope."

      artemis-assets := {
        // TODO(florian): share the keys of the assets with the Artemis service.
        "broker": {
          "format": "tison",
          "json": broker-json,
        },
        "artemis.broker": {
          "format": "tison",
          "json": artemis-json,
        },
      }
      der-certificates.do: | name/string value/ByteArray |
        // The 'server_config_to_service_json' function puts the certificates
        // into their own namespace.
        assert: name.starts-with "certificate-"
        artemis-assets[name] = {
          "format": "binary",
          "blob": value,
        }

      artemis-assets["device-config"] = {
        "format": "ubjson",
        "json": device-config,
      }

      artemis-assets-path := "$tmp-dir/artemis.assets"
      sdk.assets-create --output-path=artemis-assets-path artemis-assets

      // Get the prebuilt Artemis service.
      artemis-service-image-path := get-service-image-path_
          --organization-id=organization-id
          --word-size=32  // TODO(florian): we should get the bits from the envelope.
          --sdk=sdk-version
          --service=service-version

      sdk.firmware-add-container "artemis"
          --envelope=output-path
          --assets=artemis-assets-path
          --program-path=artemis-service-image-path
          --trigger="boot"
          --critical

    // For convenience save all snapshots in the user's cache.
    cache-snapshots --envelope-path=output-path --cache=cache_

  /**
  Builds a container description as needed for a "container" entry in the device state.
  */
  build-container-description_ -> Map
      --id/uuid.Uuid
      --arguments/List?
      --background/bool?
      --critical/bool?
      --runlevel/int?
      --triggers/List?:
    result := {
      "id": id.stringify,
    }
    if arguments and not arguments.is-empty:
      result["arguments"] = arguments
    if background:
      result["background"] = 1
    if critical:
      result["critical"] = 1
    if runlevel:
      result["runlevel"] = runlevel
    if triggers and not triggers.is-empty:
      trigger-map := {:}
      triggers.do: | trigger/Trigger |
        assert: not trigger-map.contains trigger.type
        trigger-map[trigger.type] = trigger.json-value
      result["triggers"] = trigger-map
    return result

  /**
  Uploads the given $pod to the server under the given $organization-id.

  Uploads the trivial patches and the pod itself.

  Once uploaded, the pod can be used for diff-based updates, or simply as direct
    downloads for updates.
  */
  upload --pod/Pod --organization-id/uuid.Uuid:
    firmware-content := FirmwareContent.from-envelope pod.envelope-path --cache=cache_
    upload --firmware-content=firmware-content --organization-id=organization-id

  upload --firmware-content/FirmwareContent --organization-id/uuid.Uuid:
    firmware-content.trivial-patches.do:
      upload-patch it --organization-id=organization-id
  /**
  Uploads the given $patch to the server under the given $organization-id.
  */
  upload-patch patch/FirmwarePatch --organization-id/uuid.Uuid:
    diff-and-upload_ patch --organization-id=organization-id

  /**
  Extracts the trivial patches from the given $firmware-content.

  Returns a mapping from patch-id (as used when diffing to the part) and
    the patch itself.
  */
  extract-trivial-patches firmware-content/FirmwareContent -> Map:
    result := {:}
    firmware-content.trivial-patches.do: | patch/FirmwarePatch |
      patch-id := id_ --to=patch.to_
      result[patch-id] = patch
    return result

  update --device-id/uuid.Uuid --pod/Pod --base-firmwares/List=[]:
    devices := connected-broker.get-devices --device-ids=[device-id]
    if devices.is-empty:
      ui_.abort "Device '$device-id' not found."
    device := devices[device-id]
    update-bulk --devices=[device] --pods=[pod] --base-firmwares=base-firmwares

  /**
  Update the given $devices.

  The lists $devices and $pods must have the same size.

  The $devices list must contain $DeviceDetailed objects.
  The $pods list must contain $Pod objects.

  Uploads the $pods if they it haven't been uploaded yet.
  For each device computes upgrade-patches and uploads them if needed.

  If a device has no known current state, then uses the $base-firmwares
    (a list of $FirmwareContent) for diff-based patches. If the list
    is empty, the device must upgrade using trivial patches.

  Trivial patches are always uploaded (as part of the pod upload).
  */
  update-bulk --devices/List --pods/List --base-firmwares/List=[] -> none:
    unconfigured-cache := {:}

    goals := []
    devices.size.repeat: | i |
      device := devices[i]
      pod := pods[i]
      unconfigured := unconfigured-cache.get pod.id --init=:
        FirmwareContent.from-envelope pod.envelope-path --cache=cache_

      goal := prepare-update-device_
          --device=device
          --pod=pod
          --unconfigured-content=unconfigured
          --base-firmwares=base-firmwares
      goals.add goal

    connected-broker.update-goals
        --device-ids=devices.map: it.id
        --goals=goals

  /**
  Prepares the update for the given $device.

  Computes the patch and uploads it.
  Returns the new goal state for the device.
  */
  prepare-update-device_ --device/DeviceDetailed --pod/Pod --unconfigured-content/FirmwareContent --base-firmwares/List -> Map:
    device-id := device.id
    upload --firmware-content=unconfigured-content --organization-id=device.organization-id

    known-encoded-firmwares := {}
    [
      device.goal,
      device.reported-state-firmware,
      device.reported-state-current,
      device.reported-state-goal,
    ].do: | state/Map? |
      // The device might be running this firmware.
      if state: known-encoded-firmwares.add state["firmware"]

    upgrade-from := []
    if known-encoded-firmwares.is-empty:
      if base-firmwares.is-empty:
        ui_.warning "Firmware of device '$device-id' is unknown. Upgrade might not use patches."
      else:
        upgrade-from = base-firmwares
    else:
      known-encoded-firmwares.do: | encoded/string |
        old-firmware := Firmware.encoded encoded
        old-device-map := old-firmware.device-specific "artemis.device"
        old-device-id := uuid.parse old-device-map["device_id"]
        if device-id != old-device-id:
          ui_.abort "The device id of the firmware image ($old-device-id) does not match the given device id ($device-id)."
        upgrade-from.add old-firmware.content

    result := compute-updated-goal
        --device=device
        --upgrade-from=upgrade-from
        --pod=pod
        --unconfigured-content=unconfigured-content
    return result

  /**
  Computes the goal for the given $device, upgrading from the $upgrade-from
    firmware content entries to the firmware image given by the $pod.

  Uploads the patches to the broker in the same organization as the $device.

  The returned goal state will instruct the device to download the firmware image
    and install it.
  */
  compute-updated-goal --device/Device --upgrade-from/List --pod/Pod --unconfigured-content/FirmwareContent -> Map:
    // Compute the patches and upload them.
    ui_.info "Computing and uploading patches for $device.id."
    upgrade-to := Firmware --pod=pod --device=device --cache=cache_ --unconfigured-content=unconfigured-content
    upgrade-from.do: | old-firmware-content/FirmwareContent |
      patches := upgrade-to.content.patches old-firmware-content
      patches.do: diff-and-upload_ it --organization-id=device.organization-id

    // Build the updated goal and return it.
    sdk := get-sdk pod.sdk-version --cache=cache_
    goal := (pod.device-config --sdk=sdk).copy
    goal["firmware"] = upgrade-to.encoded
    return goal

  /**
  Computes the device-specific data of the given envelope.

  Combines the $pod and identity ($identity-path) into a single firmware image
    and computes the configuration which depends on the checksums of the
    individual parts.

  In this context the configuration consists of the checksums of the individual
    parts of the firmware image, combined with the configuration that was
    stored in the envelope.
  */
  compute-device-specific-data --pod/Pod --identity-path/string -> ByteArray:
    return compute-device-specific-data
        --pod=pod
        --identity-path=identity-path
        --cache=cache_
        --ui=ui_

  /**
  Variant of $(compute-device-specific-data --pod --identity-path).
  */
  static compute-device-specific-data -> ByteArray
      --pod/Pod
      --identity-path/string
      --cache/cache.Cache
      --ui/Ui:
    // Use the SDK from the pod.
    sdk := get-sdk pod.sdk-version --cache=cache

    // Extract the device ID from the identity file.
    // TODO(florian): abstract the identity management.
    identity-raw := file.read-content identity-path

    identity := ubjson.decode (base64.decode identity-raw)

    // Since we already have the identity content, check that the artemis server
    // is the same.
    // This is primarily a sanity check, and we might remove the broker from the
    // identity file in the future. Since users are not supposed to be able to
    // change the Artemis server, there wouldn't be much left of the check.
    // TODO(florian): remove this check?
    with-tmp-directory: | tmp/string |
      artemis-assets-path := "$tmp/artemis.assets"
      sdk.run-firmware-tool [
        "-e", pod.envelope-path,
        "container", "extract",
        "-o", artemis-assets-path,
        "--part", "assets",
        "artemis"
      ]

      if not is-same-broker "broker" identity tmp artemis-assets-path sdk:
        ui.warning "The identity file and the Artemis assets in the envelope don't use the same broker"
      if not is-same-broker "artemis.broker" identity tmp artemis-assets-path sdk:
        ui.warning "The identity file and the Artemis assets in the envelope don't use the same Artemis server"

    device-map := identity["artemis.device"]
    device := Device
        --hardware-id=uuid.parse device-map["hardware_id"]
        --id=uuid.parse device-map["device_id"]
        --organization-id=uuid.parse device-map["organization_id"]

    // We don't really need the full firmware and just the device-specific data,
    // but by cooking the firmware we get the checksums correct.
    firmware := Firmware --pod=pod --device=device --cache=cache

    return firmware.device-specific-data

  /**
  Gets the Artemis service image for the given $sdk and $service versions.

  Returns a path to the cached image.
  */
  get-service-image-path_ -> string
      --organization-id/uuid.Uuid
      --sdk/string
      --service/string
      --word-size/int:
    if word-size != 32 and word-size != 64: throw "INVALID_ARGUMENT"
    service-key := service-image-cache-key
        --service-version=service
        --sdk-version=sdk
        --artemis-config=artemis-config_
    return cache_.get-file-path service-key: | store/cache.FileStore |
      server := connected-artemis-server --no-authenticated
      entry := server.list-sdk-service-versions
          --organization-id=organization-id
          --sdk-version=sdk
          --service-version=service
      if entry.is-empty:
        ui_.abort "Unsupported Artemis/SDK versions."
      image-name := entry.first["image"]
      service-image-bytes := server.download-service-image image-name
      ar-reader := ar.ArReader.from-bytes service-image-bytes
      ar-file := ar-reader.find "service-$(word-size).img"
      store.save ar-file.content

  /**
  Updates the goal state of the device with the given $device-id.

  See $BrokerCli.update-goal.
  */
  update-goal --device-id/uuid.Uuid [block]:
    connected-broker.update-goal --device-id=device-id block

  container-install -> none
      --device-id/uuid.Uuid
      --app-name/string
      --application-path/string
      --arguments/List?
      --background/bool
      --critical/bool
      --triggers/List?:
    update-goal --device-id=device-id: | device/DeviceDetailed |
      current-state := device.reported-state-current or device.reported-state-firmware
      if not current-state:
        ui_.abort "Unknown device state."
      firmware := Firmware.encoded current-state["firmware"]
      sdk-version := firmware.sdk-version
      sdk := get-sdk sdk-version --cache=cache_
      program := CompiledProgram.application application-path --sdk=sdk
      id := program.id

      cache-id := application-image-cache-key id --broker-config=broker-config_
      cache_.get-directory-path cache-id: | store/cache.DirectoryStore |
        store.with-tmp-directory: | tmp-dir |
          // TODO(florian): do we want to rely on the cache, or should we
          // do a check to see if the files are really uploaded?
          connected-broker.upload-image program.image32
              --app-id=id
              --organization-id=device.organization-id
              --word-size=32
          file.write-content program.image32 --path="$tmp-dir/image32.bin"
          connected-broker.upload-image program.image64
              --organization-id=device.organization-id
              --app-id=id
              --word-size=64
          file.write-content program.image64 --path="$tmp-dir/image64.bin"
          store.move tmp-dir

      if not device.goal and not device.reported-state-firmware:
        throw "No known firmware information for device."
      new-goal := device.goal or device.reported-state-firmware
      ui_.info "Installing container '$app-name'."
      apps := new-goal.get "apps" --if-absent=: {:}
      apps[app-name] = build-container-description_
          --id=id
          --arguments=arguments
          --background=background
          --critical=critical
          --runlevel=null  // TODO(florian): should we allow to set the runlevel?
          --triggers=triggers
      new-goal["apps"] = apps
      new-goal

  container-uninstall --device-id/uuid.Uuid --app-name/string --force/bool:
    update-goal --device-id=device-id: | device/DeviceDetailed |
      if not device.goal and not device.reported-state-firmware:
        throw "No known firmware information for device."
      new-goal := device.goal or device.reported-state-firmware
      connections/List := new-goal.get "connections" --if-absent=: []
      is-required := false
      connections.do:
        required := it.get "requires" --if-absent=: []
        if required.contains app-name:
          is-required = true
      if is-required and not force:
        ui_.abort "Container '$app-name' is required by a connection."
      apps := new-goal.get "apps"
      if apps:
        if not apps.contains app-name and not force:
          ui_.abort "Container '$app-name' is not installed."
        else:
          ui_.info "Uninstalling container '$app-name'."
          apps.remove app-name
      new-goal

  config-set-max-offline --device-id/uuid.Uuid --max-offline-seconds/int:
    update-goal --device-id=device-id: | device/DeviceDetailed |
      if not device.goal and not device.reported-state-firmware:
        throw "No known firmware information for device."
      new-goal := device.goal or device.reported-state-firmware
      ui_.info "Setting max-offline to $(Duration --s=max-offline-seconds)."
      if max-offline-seconds > 0:
        new-goal["max-offline"] = max-offline-seconds
      else:
        new-goal.remove "max-offline"
      new-goal

  /**
  Computes patches and uploads them to the broker.
  */
  diff-and-upload_ patch/FirmwarePatch --organization-id/uuid.Uuid -> none:
    trivial-id := id_ --to=patch.to_
    cache-key := "$connected-broker.id/$organization-id/patches/$trivial-id"

    // Unless it is already cached, always create/upload the trivial one.
    cache_.get cache-key: | store/cache.FileStore |
      trivial := build-trivial-patch patch.bits_
      connected-broker.upload-firmware trivial
          --organization-id=organization-id
          --firmware-id=trivial-id
      store.save-via-writer: | writer/writer.Writer |
        trivial.do: writer.write it

    if not patch.from_: return

    // Attempt to fetch the old trivial patch and use it to construct
    // the old bits so we can compute a diff from them.
    old-id := id_ --to=patch.from_
    cache-key = "$connected-broker.id/$organization-id/patches/$old-id"
    trivial-old := cache_.get cache-key: | store/cache.FileStore |
      downloaded := null
      catch: downloaded = connected-broker.download-firmware
          --organization-id=organization-id
          --id=old-id
      if not downloaded: return
      store.with-tmp-directory: | tmp-dir |
        file.write-content downloaded --path="$tmp-dir/patch"
        // TODO(florian): we don't have the chunk-size when downloading from the broker.
        store.move "$tmp-dir/patch"

    bitstream := bytes.Reader trivial-old
    patcher := Patcher bitstream null
    patch-writer := PatchWriter
    if not patcher.patch patch-writer: return
    // Build the old bits and check that we get the correct hash.
    old := patch-writer.buffer.bytes
    if old.size < patch-writer.size: old += ByteArray (patch-writer.size - old.size)
    sha := sha256.Sha256
    sha.add old
    if patch.from_ != sha.get: return

    diff-id := id_ --from=patch.from_ --to=patch.to_
    cache-key = "$connected-broker.id/$organization-id/patches/$diff-id"
    cache_.get cache-key: | store/cache.FileStore |
      // Build the diff and verify that we can apply it and get the
      // correct hash out before uploading it.
      diff := build-diff-patch old patch.bits_
      if patch.to_ != (compute-applied-hash_ diff old): return
      diff-size-bytes := diff.reduce --initial=0: | size chunk | size + chunk.size
      diff-size := diff-size-bytes > 4096
          ? "$((diff-size-bytes + 1023) / 1024) KB"
          : "$diff-size-bytes B"
      ui_.info "Uploading patch $(base64.encode patch.to_ --url-mode) ($diff-size)."
      connected-broker.upload-firmware diff
          --organization-id=organization-id
          --firmware-id=diff-id
      store.save-via-writer: | writer/writer.Writer |
        diff.do: writer.write it

  static id_ --from/ByteArray?=null --to/ByteArray -> string:
    folder := base64.encode to --url-mode
    entry := from ? (base64.encode from --url-mode) : "none"
    return "$folder/$entry"

  static compute-applied-hash_ diff/List old/ByteArray -> ByteArray?:
    combined := diff.reduce --initial=#[]: | acc chunk | acc + chunk
    bitstream := bytes.Reader combined
    patcher := Patcher bitstream old
    writer := PatchWriter
    if not patcher.patch writer: return null
    sha := sha256.Sha256
    sha.add writer.buffer.bytes
    return sha.get

is-same-broker broker/string identity/Map tmp/string assets-path/string sdk/Sdk -> bool:
  broker-path := "$tmp/broker.json"
  sdk.run-assets-tool [
    "-e", assets-path,
    "get", "--format=tison",
    "-o", broker-path,
    "broker"
  ]
  // TODO(kasper): This is pretty crappy.
  x := ((json.stringify identity["broker"]) + "\n").to-byte-array
  y := (file.read-content broker-path)
  return x == y
