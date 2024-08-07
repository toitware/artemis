// Copyright (C) 2024 Toitware ApS. All rights reserved.

import cli show Cli FileStore DirectoryStore
import crypto.sha256
import host.file
import host.os
import io
import net
import uuid

import encoding.base64
import encoding.ubjson

import .artemis
import .cache
import .config
import .device
import .pod
import .pod-specification

import .utils
import .utils.patch-build show build-diff-patch build-trivial-patch
import ..shared.utils.patch show Patcher PatchObserver

import .brokers.broker
import .event
import .firmware
import .pod-registry
import .program
import .sdk
import .server-config

class UploadResult:
  fleet-id/uuid.Uuid
  id/uuid.Uuid
  name/string
  revision/int
  tags/List
  tag-errors/List

  constructor --.fleet-id --.id --.name --.revision --.tags --.tag-errors:

  to-json -> Map:
    result := {
      "fleet-id": "$fleet-id",
      "id": "$id",
      "name": name,
      "revision": revision,
      "tags": tags,
    }
    if not tag-errors.is-empty:
      result["tag-errors"] = tag-errors
    return result

class PodBroker:
  id/uuid.Uuid
  name/string?
  revision/int?
  tags/List?

  constructor --.id --.name --.revision --.tags:

/**
Manages devices that have an Artemis service running on them.
*/
class Broker:
  fleet-id/uuid.Uuid
  organization-id/uuid.Uuid
  server-config/ServerConfig
  cli_/Cli
  network_/net.Client? := null
  tmp-directory_/string
  /**
  A mapping from device-id to a representative short string.

  This field is only set if the fleet has devices.
  */
  device-short-strings_/Map?

  broker-connection__/BrokerCli? := null

  constructor
      --.fleet-id/uuid.Uuid
      --.organization-id/uuid.Uuid
      --.server-config
      --cli/Cli
      --tmp-directory/string
      --short-strings/Map?:
    cli_ = cli
    tmp-directory_ = tmp-directory
    device-short-strings_ = short-strings

  /** Opens the network. */
  connect-network_:
    if network_: return
    network_ = net.open

  broker-connection_ -> BrokerCli:
    if not broker-connection__:
      broker-connection__ = BrokerCli server-config --cli=cli_
      broker-connection__.ensure-authenticated: | error-message |
        cli_.ui.abort "$error-message (broker)."
    return broker-connection__

  short-string-for_ --device-id/uuid.Uuid -> string:
    if not device-short-strings_: throw "Access to device in non-device fleet."
    return device-short-strings_[device-id]

  /**
  Ensures that the broker is authenticated.
  */
  ensure-authenticated:
    broker-connection_

  /**
  Closes the broker.

  If the broker opened any connections, closes them as well.
  */
  close:
    if broker-connection__:
      broker-connection__.close
      broker-connection__ = null
    if network_:
      network_.close
      network_ = null

  /**
  Uploads the given $pod to the broker for the given $fleet-id in $organization-id.

  Also uploads the trivial patches.
  */
  upload --pod/Pod --tags/List --force-tags/bool -> UploadResult:
    upload-trivial-patches_ --pod=pod

    pod.split: | manifest/Map parts/Map |
      parts.do: | id/string content/ByteArray |
        // Only upload if we don't have it in our cache.
        key := cache-key-pod-parts
            --broker-config=server-config
            --organization-id=organization-id
            --part-id=id
        cli_.cache.get-file-path key: | store/FileStore |
          broker-connection_.pod-registry-upload-pod-part content --part-id=id
              --organization-id=organization-id
          store.save content
      key := cache-key-pod-manifest
          --broker-config=server-config
          --organization-id=organization-id
          --pod-id=pod.id
      cli_.cache.get-file-path key: | store/FileStore |
        encoded := ubjson.encode manifest
        broker-connection_.pod-registry-upload-pod-manifest encoded --pod-id=pod.id
            --organization-id=organization-id
        store.save encoded

    description-ids := broker-connection_.pod-registry-descriptions
        --fleet-id=fleet-id
        --organization-id=organization-id
        --names=[pod.name]
        --create-if-absent

    description-id := (description-ids[0] as PodRegistryDescription).id

    broker-connection_.pod-registry-add
        --pod-description-id=description-id
        --pod-id=pod.id

    is-existing-tag-error := : | error |
      error is string and
        (error.contains "duplicate key value" or error.contains "already exists")

    tag-errors := []
    tags.do: | tag/string |
      force := force-tags or (tag == "latest")
      exception := catch --unwind=(: not is-existing-tag-error.call it):
        broker-connection_.pod-registry-tag-set
            --pod-description-id=description-id
            --pod-id=pod.id
            --tag=tag
            --force=force
      if exception:
        tag-errors.add "Tag '$tag' already exists for pod $pod.name."

    registered-pods := broker-connection_.pod-registry-pods --fleet-id=fleet-id --pod-ids=[pod.id]
    pod-entry/PodRegistryEntry := registered-pods[0]

    sorted-uploaded-tags := pod-entry.tags.sort
    return UploadResult
        --fleet-id=fleet-id
        --id=pod.id
        --name=pod.name
        --revision=pod-entry.revision
        --tags=sorted-uploaded-tags
        --tag-errors=tag-errors

  upload-trivial-patches_ --pod/Pod -> none:
    firmware-content := FirmwareContent.from-envelope pod.envelope-path --cli=cli_
    upload_ --firmware-content=firmware-content

  upload_ --firmware-content/FirmwareContent:
    firmware-content.trivial-patches.do:
      upload-patch_ it

  /**
  Uploads the given $patch to the server under the given $organization-id.
  */
  upload-patch_ patch/FirmwarePatch:
    diff-and-upload_ patch

  /**
  Computes patches and uploads them to the broker.
  */
  diff-and-upload_ patch/FirmwarePatch -> none:
    // Unless it is already cached, always create/upload the trivial one.
    trivial-id := id_ --to=patch.to_
    cache-key := cache-key-patch
        --broker-config=server-config
        --organization-id=organization-id
        --patch-id=trivial-id
    cli_.cache.get cache-key: | store/FileStore |
      trivial := build-trivial-patch patch.bits_
      broker-connection_.upload-firmware trivial
          --organization-id=organization-id
          --firmware-id=trivial-id
      store.save-via-writer: | writer/io.Writer |
        trivial.do: writer.write it

    if not patch.from_: return

    // Attempt to fetch the old trivial patch and use it to construct
    // the old bits so we can compute a diff from them.
    old-id := id_ --to=patch.from_
    cache-key = cache-key-patch
        --broker-config=server-config
        --organization-id=organization-id
        --patch-id=old-id
    trivial-old := cli_.cache.get cache-key: | store/FileStore |
      downloaded := null
      catch: downloaded = broker-connection_.download-firmware
          --organization-id=organization-id
          --id=old-id
      if not downloaded:
        cli_.ui.warning "Failed to download old firmware for patch $old-id -> $trivial-id."
        return
      store.with-tmp-directory: | tmp-dir |
        file.write-content downloaded --path="$tmp-dir/patch"
        // TODO(florian): we don't have the chunk-size when downloading from the broker.
        store.move "$tmp-dir/patch"

    bitstream := io.Reader trivial-old
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
    cache-key = cache-key-patch
        --broker-config=server-config
        --organization-id=organization-id
        --patch-id=diff-id
    cli_.cache.get cache-key: | store/FileStore |
      // Build the diff and verify that we can apply it and get the
      // correct hash out before uploading it.
      diff := build-diff-patch old patch.bits_
      if patch.to_ != (compute-applied-hash_ diff old): return
      diff-size-bytes := diff.reduce --initial=0: | size chunk | size + chunk.size
      diff-size := diff-size-bytes > 4096
          ? "$((diff-size-bytes + 1023) / 1024) KB"
          : "$diff-size-bytes B"
      from64 := base64.encode patch.from_ --url-mode
      to64 := base64.encode patch.to_ --url-mode
      cli_.ui.info "Uploading patch $from64 -> $to64 ($diff-size)."
      broker-connection_.upload-firmware diff
          --organization-id=organization-id
          --firmware-id=diff-id
      store.save-via-writer: | writer/io.Writer |
        diff.do: writer.write it

  static id_ --from/ByteArray?=null --to/ByteArray -> string:
    folder := base64.encode to --url-mode
    entry := from ? (base64.encode from --url-mode) : "none"
    return "$folder/$entry"

  static compute-applied-hash_ diff/List old/ByteArray -> ByteArray?:
    combined := diff.reduce --initial=#[]: | acc chunk | acc + chunk
    bitstream := io.Reader combined
    patcher := Patcher bitstream old
    writer := PatchWriter
    if not patcher.patch writer: return null
    sha := sha256.Sha256
    sha.add writer.buffer.bytes
    return sha.get

  is-cached --pod-id/uuid.Uuid -> bool:
    manifest-key := cache-key-pod-manifest
        --broker-config=server-config
        --organization-id=organization-id
        --pod-id=pod-id
    return cli_.cache.contains manifest-key

  download --pod-id/uuid.Uuid -> Pod:
    manifest-key := cache-key-pod-manifest
        --broker-config=server-config
        --organization-id=organization-id
        --pod-id=pod-id
    encoded-manifest := cli_.cache.get manifest-key: | store/FileStore |
      bytes := broker-connection_.pod-registry-download-pod-manifest
        --pod-id=pod-id
        --organization-id=organization-id
      store.save bytes
    manifest := ubjson.decode encoded-manifest
    return Pod.from-manifest
        manifest
        --tmp-directory=tmp-directory_
        --download=: | part-id/string |
          key := cache-key-pod-parts
              --broker-config=server-config
              --organization-id=organization-id
              --part-id=part-id
          cli_.cache.get key: | store/FileStore |
            bytes := broker-connection_.pod-registry-download-pod-part
                part-id
                --organization-id=organization-id
            store.save bytes

  list-pods --names/List -> Map:
    descriptions := ?
    if names.is-empty:
      descriptions = broker-connection_.pod-registry-descriptions --fleet-id=fleet-id
    else:
      descriptions = broker-connection_.pod-registry-descriptions
          --fleet-id=fleet-id
          --organization-id=organization-id
          --names=names
          --no-create-if-absent
    result := {:}
    descriptions.do: | description/PodRegistryDescription |
      pods := broker-connection_.pod-registry-pods --pod-description-id=description.id
      result[description] = pods
    return result

  delete --description-names/List:
    descriptions := broker-connection_.pod-registry-descriptions
        --fleet-id=fleet-id
        --organization-id=organization-id
        --names=description-names
        --no-create-if-absent
    unknown-pod-descriptions := []
    description-names.do: | name/string |
      was-found := descriptions.any: | description/PodRegistryDescription |
        description.name == name
      if not was-found: unknown-pod-descriptions.add name
    if not unknown-pod-descriptions.is-empty:
      if unknown-pod-descriptions.size == 1:
        cli_.ui.abort "Unknown pod '$unknown-pod-descriptions[0]'."
      else:
        quoted := unknown-pod-descriptions.map: "'$it'"
        joined := quoted.join ", "
        cli_.ui.abort "Unknown pods $joined."
    broker-connection_.pod-registry-descriptions-delete
        --fleet-id=fleet-id
        --description-ids=descriptions.map: it.id

  delete --pod-references/List:
    pod-ids := get-pod-ids pod-references
    delete --pod-ids=pod-ids

  delete --pod-ids/List:
    broker-connection_.pod-registry-delete
        --fleet-id=fleet-id
        --pod-ids=pod-ids

  get-pod-ids references/List -> List:
    references.do: | reference/PodReference |
      if not reference.id:
        if not reference.name:
          throw "Either id or name must be specified: $reference"
        if not reference.tag and not reference.revision:
          throw "Either tag or revision must be specified: $reference"

    missing-ids := references.filter: | reference/PodReference |
      not reference.id
    pod-ids-response := broker-connection_.pod-registry-pod-ids
        --fleet-id=fleet-id
        --references=missing-ids

    has-errors := false
    result := references.map: | reference/PodReference |
      if reference.id: continue.map reference.id
      resolved := pod-ids-response.get reference
      if not resolved:
        has-errors = true
        if reference.tag:
          cli_.ui.error "No pod with name '$reference.name' and tag '$reference.tag' in the fleet."
        else:
          cli_.ui.error "No pod with name '$reference.name' and revision $reference.revision in the fleet."
      resolved
    if has-errors: cli_.ui.abort
    return result

  pod pod-id/uuid.Uuid -> PodBroker:
    pod-entry := broker-connection_.pod-registry-pods
        --fleet-id=fleet-id
        --pod-ids=[pod-id]
    if not pod-entry.is-empty:
      description-id := pod-entry[0].pod-description-id
      description := broker-connection_.pod-registry-descriptions --ids=[description-id]
      if not description.is-empty:
        return PodBroker --id=pod-id --name=description[0].name --revision=pod-entry[0].revision --tags=pod-entry[0].tags

    return PodBroker --id=pod-id --name=null --revision=null --tags=null

  get-pod-id reference/PodReference -> uuid.Uuid:
    return (get-pod-ids [reference])[0]

  get-pod-id --name/string --tag/string? --revision/int? -> uuid.Uuid:
    return get-pod-id (PodReference --name=name --tag=tag --revision=revision)

  pod-exists reference/PodReference -> bool:
    pod-id := get-pod-id reference
    pod-entry := broker-connection_.pod-registry-pods
        --fleet-id=fleet-id
        --pod-ids=[pod-id]
    return not pod-entry.is-empty

  /**
  Fetches the device details for the given device ids.
  Returns a map from id to $DeviceDetailed.
  */
  get-devices --device-ids/List -> Map:
    return broker-connection_.get-devices --device-ids=device-ids

  update --device-id/uuid.Uuid --pod/Pod --base-firmwares/List=[]:
    update-bulk_ --devices=[device-for --id=device-id] --pods=[pod] --base-firmwares=base-firmwares

  /**
  Rolls out.

  If $warn-only-trivial is true, then emits a warning if the device has no known
    current state and the base-firmwares list is empty. In this case, the device
    must upgrade using trivial patches.
  */
  roll-out -> none
      --devices/List  // Of DeviceDetailed.
      --pods/List
      --diff-bases/List  // Of Pod.
      --warn-only-trivial/bool=true:
    base-patches := {:}

    base-firmwares := diff-bases.map: | diff-base/Pod |
      FirmwareContent.from-envelope diff-base.envelope-path --cli=cli_

    base-firmwares.do: | content/FirmwareContent |
      trivial-patches := extract-trivial-patches_ content
      trivial-patches.do: | _ patch/FirmwarePatch |
        upload-patch_ patch

    update-bulk_
        --devices=devices
        --pods=pods
        --base-firmwares=base-firmwares
        --warn-only-trivial=warn-only-trivial
  /**
  Extracts the trivial patches from the given $firmware-content.

  Returns a mapping from patch-id (as used when diffing to the part) and
    the patch itself.
  */
  extract-trivial-patches_ firmware-content/FirmwareContent -> Map:
    result := {:}
    firmware-content.trivial-patches.do: | patch/FirmwarePatch |
      patch-id := id_ --to=patch.to_
      result[patch-id] = patch
    return result

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
  update-bulk_ -> none
      --devices/List
      --pods/List
      --base-firmwares/List=[]
      --warn-only-trivial/bool=true:
    unconfigured-cache := {:}

    goals := []
    devices.size.repeat: | i |
      device := devices[i]
      pod := pods[i]
      unconfigured := unconfigured-cache.get pod.id --init=:
        FirmwareContent.from-envelope pod.envelope-path --cli=cli_

      goal := prepare-update-device_
          --device=device
          --pod=pod
          --unconfigured-content=unconfigured
          --base-firmwares=base-firmwares
          --warn-only-trivial=warn-only-trivial
      goals.add goal

    broker-connection_.update-goals
        --device-ids=devices.map: it.id
        --goals=goals

  /**
  Prepares the update for the given $device.

  Computes the patch and uploads it.
  Returns the new goal state for the device.
  */
  prepare-update-device_ -> Map
      --device/DeviceDetailed
      --pod/Pod
      --unconfigured-content/FirmwareContent
      --base-firmwares/List
      --warn-only-trivial/bool=true:
    device-id := device.id
    upload_ --firmware-content=unconfigured-content

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
        short := short-string-for_ --device-id=device-id
        if warn-only-trivial:
          cli_.ui.warning "Firmware of device $short is unknown. Upgrade might not use patches."
      else:
        upgrade-from = base-firmwares
    else:
      known-encoded-firmwares.do: | encoded/string |
        old-firmware := Firmware.encoded encoded
        old-device-map := old-firmware.device-specific "artemis.device"
        old-device-id := uuid.parse old-device-map["device_id"]
        if device-id != old-device-id:
          cli_.ui.abort "The device id of the firmware image ($old-device-id) does not match the given device id ($device-id)."
        upgrade-from.add old-firmware.content

    result := compute-updated-goal_
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
  compute-updated-goal_ --device/Device --upgrade-from/List --pod/Pod --unconfigured-content/FirmwareContent -> Map:
    // Compute the patches and upload them.
    short := short-string-for_ --device-id=device.id
    cli_.ui.info "Computing and uploading patches for $short."
    upgrade-to := Firmware
        --pod=pod
        --device=device
        --unconfigured-content=unconfigured-content
        --cli=cli_
    upgrade-from.do: | old-firmware-content/FirmwareContent |
      patches := upgrade-to.content.patches old-firmware-content
      patches.do: diff-and-upload_ it

    // Build the updated goal and return it.
    sdk := get-sdk pod.sdk-version --cli=cli_
    goal := (pod.device-config --sdk=sdk).copy
    goal["firmware"] = upgrade-to.encoded
    return goal

  get-goal-request-events --device-ids/List --limit/int -> Map:
    return broker-connection_.get-events
        --device-ids=device-ids
        --limit=limit
        --types=["get-goal"]

  /**
  For each device in the given $device-ids, fetches the last event the
    device sent.
  Returns a map from device-id to $Event.
  */
  get-last-events --device-ids/List -> Map:
    result := broker-connection_.get-events
        --device-ids=device-ids
        --limit=1
    result.map --in-place: | _ events/List | events[0]
    return result

  /**
  For each device in the given $device-ids, fetches $limit events of the given
    $types. If $types is null, all events are returned.

  Returns a map from device-id to List of $Event.
  */
  get-events --device-ids/List --limit/int --types/List? -> Map:
    return broker-connection_.get-events
        --device-ids=device-ids
        --limit=limit
        --types=types

  /**
  Fetches the pod information for the given $pod-ids.

  Returns a map from pod id to $PodRegistryEntry.
  */
  get-pod-registry-entry-map --pod-ids/List -> Map:
    pod-id-entries := broker-connection_.pod-registry-pods
        --fleet-id=fleet-id
        --pod-ids=pod-ids
    pod-entry-map := {:}
    pod-id-entries.do: | entry/PodRegistryEntry |
      pod-entry-map[entry.id] = entry
    return pod-entry-map

  /**
  Returns a map from description-id to $PodRegistryDescription.

  The given $pod-registry-entries must be a list of $PodRegistryEntry instances.
  */
  get-pod-descriptions --pod-registry-entries/List -> Map:
    description-set := {}
    description-set.add-all
        (pod-registry-entries.map: | entry/PodRegistryEntry | entry.pod-description-id)
    description-ids := []
    description-ids.add-all description-set
    descriptions := broker-connection_.pod-registry-descriptions --ids=description-ids
    description-map := {:}
    descriptions.do: | description/PodRegistryDescription |
      description-map[description.id] = description
    return description-map

  notify-created device/Device -> none:
    identity := {
      "device_id": "$device.id",
      "organization_id": "$device.organization-id",
      "hardware_id": "$device.hardware-id",
    }
    state := {
      "identity": identity,
    }
    broker-connection_.notify-created --device-id=device.id --state=state

  device-for --id/uuid.Uuid -> DeviceDetailed:
    devices := broker-connection_.get-devices --device-ids=[id]
    if devices.is-empty:
      short := short-string-for_ --device-id=id
      cli_.ui.abort "Device $short does not exist on server."
    return devices[id]

  /**
  Updates the goal state of the device with the given $device-id.

  See $BrokerCli.update-goal.
  */
  update-goal_ --device-id/uuid.Uuid [block]:
    broker-connection_.update-goal --device-id=device-id block

  container-install -> none
      --device-id/uuid.Uuid
      --app-name/string
      --application-path/string
      --arguments/List?
      --background/bool
      --critical/bool
      --triggers/List?:
    update-goal_ --device-id=device-id: | device/DeviceDetailed |
      current-state := device.reported-state-current or device.reported-state-firmware
      if not current-state:
        cli_.ui.abort "Unknown device state."
      firmware := Firmware.encoded current-state["firmware"]
      sdk-version := firmware.sdk-version
      sdk := get-sdk sdk-version --cli=cli_
      program := CompiledProgram.application application-path --sdk=sdk
      id := program.id

      cache-key := cache-key-application-image id --broker-config=server-config
      cli_.cache.get-directory-path cache-key: | store/DirectoryStore |
        store.with-tmp-directory: | tmp-dir |
          // TODO(florian): do we want to rely on the cache, or should we
          // do a check to see if the files are really uploaded?
          broker-connection_.upload-image program.image32
              --app-id=id
              --organization-id=device.organization-id
              --word-size=32
          file.write-content program.image32 --path="$tmp-dir/image32.bin"
          broker-connection_.upload-image program.image64
              --organization-id=device.organization-id
              --app-id=id
              --word-size=64
          file.write-content program.image64 --path="$tmp-dir/image64.bin"
          store.move tmp-dir

      if not device.goal and not device.reported-state-firmware:
        throw "No known firmware information for device."
      new-goal := device.goal or device.reported-state-firmware
      cli_.ui.info "Installing container '$app-name'."
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
    update-goal_ --device-id=device-id: | device/DeviceDetailed |
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
        cli_.ui.abort "Container '$app-name' is required by a connection."
      apps := new-goal.get "apps" or {:}
      if apps:
        if not apps.contains app-name and not force:
          cli_.ui.abort "Container '$app-name' is not installed."
        else:
          cli_.ui.info "Uninstalling container '$app-name'."
          apps.remove app-name
          if apps.is-empty: new-goal.remove "apps"
      new-goal

  config-set-max-offline --device-id/uuid.Uuid --max-offline-seconds/int:
    update-goal_ --device-id=device-id: | device/DeviceDetailed |
      if not device.goal and not device.reported-state-firmware:
        throw "No known firmware information for device."
      new-goal := device.goal or device.reported-state-firmware
      cli_.ui.info "Setting max-offline to $(Duration --s=max-offline-seconds)."
      if max-offline-seconds > 0:
        new-goal["max-offline"] = max-offline-seconds
      else:
        new-goal.remove "max-offline"
      new-goal

  static has-implicit-network_ chip-family/string -> bool:
    return chip-family == "host"

  /**
  Customizes a generic Toit envelope with the given $specification.
    Also installs the Artemis service.

  The image is ready to be flashed together with the identity file.
  */
  customize-envelope
      --organization-id/uuid.Uuid
      --specification/PodSpecification
      --recovery-urls/List
      --artemis/Artemis
      --output-path/string:
    service-version := specification.artemis-version
    sdk-version := specification.sdk-version

    checked := false
    // We try to check the sdk and service versions as soon as possible to
    // avoid downloading expensive assets.
    check-sdk-service-version := :
      if not checked and sdk-version:
        artemis.check-is-supported-version_
            --organization-id=organization-id
            --sdk=sdk-version
            --service=service-version
        checked = true

    check-sdk-service-version.call

    envelope-path := get-envelope
        --specification=specification
        --cli=cli_

    // Extract the sdk version from the envelope.
    envelope := file.read-content envelope-path
    envelope-sdk-version := Sdk.get-sdk-version-from --envelope=envelope
    envelope-chip-family := Sdk.get-chip-family-from --envelope=envelope
    if sdk-version:
      if sdk-version != envelope-sdk-version:
        if not (is-dev-setup and os.env.get "DEV_TOIT_REPO_PATH"):
          cli_.ui.abort "The envelope uses SDK version $envelope-sdk-version, but $sdk-version was requested."
    else:
      sdk-version = envelope-sdk-version
      check-sdk-service-version.call
    envelope-word-bit-size := Sdk.get-word-bit-size-from --envelope=envelope

    sdk := get-sdk sdk-version --cli=cli_

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

    if specification.connections.is-empty and not has-implicit-network_ envelope-chip-family:
      cli_.ui.warning "No network connections configured."
    connections := specification.connections.map: | connection/ConnectionInfo |
      connection.to-json
    device-config["connections"] = connections

    // Create the assets for the Artemis service.
    // TODO(florian): share this code with the identity creation code.
    der-certificates := {:}
    broker-json := server-config-to-service-json server-config der-certificates
    artemis-json := server-config-to-service-json artemis.server-config der-certificates

    with-tmp-directory: | tmp-dir |
      // Store the containers in the envelope.
      specification.containers.do: | name/string container/Container |
        snapshot-path := "$tmp-dir/$(name).snapshot"
        container.build-snapshot
            --relative-to=specification.relative-to
            --sdk=sdk
            --output-path=snapshot-path
            --cli=cli_

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
        cli_.ui.info "Added container '$name' to envelope."

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

      artemis-assets["recovery-urls"] = {
        "format": "tison",
        "json": recovery-urls,
      }

      artemis-assets-path := "$tmp-dir/artemis.assets"
      sdk.assets-create --output-path=artemis-assets-path artemis-assets

      // Get the prebuilt Artemis service.
      artemis-service-image-path := artemis.get-service-image-path
          --organization-id=organization-id
          --chip-family=envelope-chip-family
          --word-size=envelope-word-bit-size
          --sdk=sdk-version
          --service=service-version

      sdk.firmware-add-container "artemis"
          --envelope=output-path
          --assets=artemis-assets-path
          --program-path=artemis-service-image-path
          --trigger="boot"
          --critical

    // For convenience save all snapshots in the user's cache.
    cache-snapshots --envelope-path=output-path --cli=cli_

  /**
  Builds a container description as needed for a "container" entry in the device state.
  */
  static build-container-description_ -> Map
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
