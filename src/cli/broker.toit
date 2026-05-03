// Copyright (C) 2024 Toitware ApS. All rights reserved.

import cli show Cli DirectoryStore
import crypto.sha256
import host.file
import net
import uuid show Uuid

import .cache
import .config
import .device
import .pod
import .pod-specification

import .utils
import ..shared.version

import .auth show Authenticatable
import .brokers.broker
import .brokers.broker-pod-store show BrokerPodStore
import .container-description show build-container-description
import .firmware-patches show FirmwarePatchUploader
import .organization
import .event
import .firmware
import .program
import .sdk
import .server-config

/**
Manages devices that have an Artemis service running on them.
*/
class Broker:
  fleet-id/Uuid
  organization-id/Uuid
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
      --.fleet-id/Uuid
      --.organization-id/Uuid
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
      connection := BrokerCli server-config --cli=cli_
      if connection is Authenticatable:
        (connection as Authenticatable).ensure-authenticated: | error-message |
          cli_.ui.abort "$error-message (broker)."
      broker-connection__ = connection
    return broker-connection__

  short-string-for_ --device-id/Uuid -> string:
    if not device-short-strings_: throw "Access to device in non-device fleet."
    return device-short-strings_[device-id]

  /**
  Ensures that the broker is authenticated.

  Has no effect for brokers that don't require authentication.
  */
  ensure-authenticated:
    broker-connection_

  /**
  Returns the admin interface of the broker, or null if the broker
    does not support administrative operations.
  */
  admin-connection-or-null -> AdminBrokerCli?:
    connection := broker-connection_
    if connection is AdminBrokerCli: return connection as AdminBrokerCli
    return null

  /**
  Fetches the organization with the given $id.

  Returns null if the broker doesn't support administrative operations
    or if the organization doesn't exist.
  */
  get-organization --id/Uuid -> OrganizationDetailed?:
    connection := broker-connection_
    if connection is not AdminBrokerCli:
      return null
    return (connection as AdminBrokerCli).get-organization id

  /**
  Creates a device in the organization with the given $organization-id.

  The $device-id may be null in which case the broker creates an alias.

  If the broker supports administrative operations, the device is created
    on the broker. Otherwise, a device identity is created locally.
  */
  create-device --device-id/Uuid? --organization-id/Uuid -> Device:
    connection := broker-connection_
    if connection is AdminBrokerCli:
      return (connection as AdminBrokerCli).create-device-in-organization
          --device-id=device-id
          --organization-id=organization-id
    // For non-admin brokers, create the device identity locally.
    id := device-id or random-uuid
    hardware-id := random-uuid
    return Device --hardware-id=hardware-id --id=id --organization-id=organization-id

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

  patch-uploader__/FirmwarePatchUploader? := null

  patch-uploader_ -> FirmwarePatchUploader:
    if not patch-uploader__:
      patch-uploader__ = FirmwarePatchUploader
          --broker-connection=broker-connection_
          --server-config=server-config
          --organization-id=organization-id
          --cli=cli_
    return patch-uploader__

  pod-store__/BrokerPodStore? := null

  /** Pod registry view, lazily constructed on first access. */
  pod-store -> BrokerPodStore:
    if not pod-store__:
      pod-store__ = BrokerPodStore
          --fleet-id=fleet-id
          --organization-id=organization-id
          --server-config=server-config
          --broker-connection=broker-connection_
          --patch-uploader=patch-uploader_
          --cli=cli_
          --tmp-directory=tmp-directory_
    return pod-store__

  /**
  Fetches the device details for the given device ids.
  Returns a map from id to $DeviceDetailed.
  */
  get-devices --device-ids/List -> Map:
    return broker-connection_.get-devices --device-ids=device-ids

  update --device-id/Uuid --pod/Pod --base-firmwares/List=[]:
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
      FirmwareContents.from-envelope diff-base.envelope-path --cli=cli_

    base-firmwares.do: | contents/FirmwareContents |
      patch-uploader_.upload-trivial-patches --firmware-contents=contents

    update-bulk_
        --devices=devices
        --pods=pods
        --base-firmwares=base-firmwares
        --warn-only-trivial=warn-only-trivial
  /**
  Update the given $devices.

  The lists $devices and $pods must have the same size.

  The $devices list must contain $DeviceDetailed objects.
  The $pods list must contain $Pod objects.

  Uploads the $pods if they it haven't been uploaded yet.
  For each device computes upgrade-patches and uploads them if needed.

  If a device has no known current state, then uses the $base-firmwares
    (a list of $FirmwareContents) for diff-based patches. If the list
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
        FirmwareContents.from-envelope pod.envelope-path --cli=cli_

      goal := prepare-update-device_
          --device=device
          --pod=pod
          --unconfigured-contents=unconfigured
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
      --unconfigured-contents/FirmwareContents
      --base-firmwares/List
      --warn-only-trivial/bool=true:
    device-id := device.id
    patch-uploader_.upload-trivial-patches --firmware-contents=unconfigured-contents

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
          cli_.ui.emit --warning "Firmware of device $short is unknown. Upgrade might not use patches."
      else:
        upgrade-from = base-firmwares
    else:
      known-encoded-firmwares.do: | encoded/string |
        old-firmware := Firmware.encoded encoded
        old-device-map := old-firmware.device-specific "artemis.device"
        old-device-id := Uuid.parse old-device-map["device_id"]
        if device-id != old-device-id:
          cli_.ui.abort "The device id of the firmware image ($old-device-id) does not match the given device id ($device-id)."
        upgrade-from.add old-firmware.contents

    result := compute-updated-goal_
        --device=device
        --upgrade-from=upgrade-from
        --pod=pod
        --unconfigured-contents=unconfigured-contents
    return result

  /**
  Computes the goal for the given $device, upgrading from the $upgrade-from
    firmware content entries to the firmware image given by the $pod.

  Uploads the patches to the broker in the same organization as the $device.

  The returned goal state will instruct the device to download the firmware image
    and install it.
  */
  compute-updated-goal_ --device/Device --upgrade-from/List --pod/Pod --unconfigured-contents/FirmwareContents -> Map:
    // Compute the patches and upload them.
    short := short-string-for_ --device-id=device.id
    cli_.ui.emit --info "Computing and uploading patches for $short."
    upgrade-to := Firmware
        --pod=pod
        --device=device
        --unconfigured-contents=unconfigured-contents
        --cli=cli_
    upgrade-from.do: | old-firmware-contents/FirmwareContents |
      patches := upgrade-to.contents.patches old-firmware-contents
      patches.do: patch-uploader_.diff-and-upload it

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

  device-for --id/Uuid -> DeviceDetailed:
    devices := broker-connection_.get-devices --device-ids=[id]
    if devices.is-empty:
      short := short-string-for_ --device-id=id
      cli_.ui.abort "Device $short does not exist on server."
    return devices[id]

  /**
  Updates the goal state of the device with the given $device-id.

  See $BrokerCli.update-goal.
  */
  update-goal_ --device-id/Uuid [block]:
    broker-connection_.update-goal --device-id=device-id block

  container-install -> none
      --device-id/Uuid
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
          file.write-contents program.image32 --path="$tmp-dir/image32.bin"
          broker-connection_.upload-image program.image64
              --organization-id=device.organization-id
              --app-id=id
              --word-size=64
          file.write-contents program.image64 --path="$tmp-dir/image64.bin"
          store.move tmp-dir

      if not device.goal and not device.reported-state-firmware:
        throw "No known firmware information for device."
      new-goal := device.goal or device.reported-state-firmware
      cli_.ui.emit --info "Installing container '$app-name'."
      apps := new-goal.get "apps" --if-absent=: {:}
      apps[app-name] = build-container-description
          --id=id
          --arguments=arguments
          --background=background
          --critical=critical
          --runlevel=null  // TODO(florian): should we allow to set the runlevel?
          --triggers=triggers
      new-goal["apps"] = apps
      new-goal

  container-uninstall --device-id/Uuid --app-name/string --force/bool:
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
          cli_.ui.emit --info "Uninstalling container '$app-name'."
          apps.remove app-name
          if apps.is-empty: new-goal.remove "apps"
      new-goal

  config-set-max-offline --device-id/Uuid --max-offline-seconds/int:
    update-goal_ --device-id=device-id: | device/DeviceDetailed |
      if not device.goal and not device.reported-state-firmware:
        throw "No known firmware information for device."
      new-goal := device.goal or device.reported-state-firmware
      cli_.ui.emit --info "Setting max-offline to $(Duration --s=max-offline-seconds)."
      if max-offline-seconds > 0:
        new-goal["max-offline"] = max-offline-seconds
      else:
        new-goal.remove "max-offline"
      new-goal

