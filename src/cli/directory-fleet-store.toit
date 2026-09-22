// Copyright (C) 2026 Toit contributors. All rights reserved.

import cli show Cli
import fs
import host.directory
import host.file
import uuid show Uuid

import .fleet show DeviceFleet
import .fleet-store
import .file-fleet-store show DevicesFile
import .pod-registry show PodReference
import .utils show create-directory-atomically read-json read-yaml write-json-to-file write-yaml-to-file

FLEET-STATE-SCHEMA ::= "https://toit.io/schemas/artemis/fleet-state/v1.json"

/** Creates and opens a directory containing declared fleet state. */
class DirectoryFleetStoreStrategy implements FleetStoreStrategy:
  root/string
  cli_/Cli

  constructor --.root --cli/Cli:
    cli_ = cli

  open -> FleetStore:
    metadata-path := fs.join root "fleet.yaml"
    if not file.is-file metadata-path:
      cli_.ui.abort "Fleet state '$root' is not initialized. Run 'fleet init' with the workspace selected."
    metadata := read-yaml metadata-path --if-error=: | exception |
      cli_.ui.abort "Failed to read fleet YAML '$metadata-path': $exception"
    if metadata is not Map or (metadata.get "\$schema") != FLEET-STATE-SCHEMA:
      cli_.ui.abort "Fleet state '$root' has an unsupported schema."
    id/Uuid? := null
    exception := catch: id = Uuid.parse metadata["id"]
    if exception:
      cli_.ui.abort "Fleet state '$root' has an invalid ID."
    groups-path := fs.join root "groups.json"
    encoded-groups := read-json groups-path --if-error=: | exception |
      cli_.ui.abort "Failed to read fleet groups JSON '$groups-path': $exception"
    if encoded-groups is not Map:
      cli_.ui.abort "Fleet state '$root' must contain a groups map."
    groups := encoded-groups.map: | name encoded |
      if name is not string or name.is-empty or encoded is not Map or (encoded.get "pod") is not string:
        cli_.ui.abort "Fleet state '$root' has an invalid group '$name'."
      PodReference.parse encoded["pod"] --cli=cli_
    devices := (DevicesFile.parse (fs.join root "devices.json") --cli=cli_).devices
    devices.do: | device/DeviceFleet |
      if not groups.contains device.group:
        cli_.ui.abort "Device $device.id refers to unknown group '$device.group'."
    return DirectoryFleetStore --root=root --id=id --group-pods=groups --devices=devices

  create --id/Uuid --group-pods/Map --devices/List -> FleetStore:
    create-directory-atomically root
        --if-error=(: cli_.ui.abort "Failed to create fleet state directory '$root': $it"): | staging/string |
      store := DirectoryFleetStore --root=staging --id=id --group-pods=group-pods --devices=devices
      store.save-fleet --group-pods=group-pods
      store.save-devices devices
      write-yaml-to-file (fs.join staging "fleet.yaml") {
        "\$schema": FLEET-STATE-SCHEMA,
        "id": "$id",
      }
    return open

/** Persists fleet identity, groups, and devices as reviewable files. */
class DirectoryFleetStore implements FleetStore:
  root/string
  id/Uuid
  group-pods/Map := ?
  devices/List := ?

  constructor --.root --.id --.group-pods --.devices:

  save-fleet --group-pods/Map?=null -> none:
    if not group-pods: return
    encoded := {:}
    group-pods.keys.sort.do: | name/string |
      encoded[name] = {"pod": "$(group-pods[name])"}
    atomic-write_ "groups.json": | path/string |
      write-json-to-file path encoded --pretty
    this.group-pods = group-pods

  save-devices devices/List -> none:
    atomic-write_ "devices.json": | path/string |
      (DevicesFile path devices).write
    this.devices = devices

  atomic-write_ name/string [write] -> none:
    staging := directory.mkdtemp (fs.join root ".write-")
    try:
      path := fs.join staging name
      write.call path
      file.rename path (fs.join root name)
    finally:
      directory.rmdir --recursive staging
