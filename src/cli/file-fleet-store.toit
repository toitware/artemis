// Copyright (C) 2026 Toit contributors. All rights reserved.

import cli show Cli
import encoding.base64
import host.file
import uuid show Uuid

import .fleet show DEFAULT-GROUP DeviceFleet
import .fleet-store
import .pod-specification show INITIAL-POD-NAME INITIAL-POD-SPECIFICATION
import .pod-registry show PodReference
import .server-config show
    DEFAULT-ARTEMIS-SERVER-CONFIG
    ORIGINAL-SUPABASE-SERVER-URL
    ServerConfig
    ServerConfigSupabase
import .utils show read-json write-json-to-file write-yaml-to-file
import ..shared.scope show Scope

/** Reads and writes the combined legacy `fleet.json` representation. */
class FleetFile:
  static JSON-SCHEMA ::= "https://toit.io/schemas/artemis/fleet/v2.json"

  path/string
  id/Uuid
  group-pods/Map
  is-reference/bool
  broker-name/string
  migrating-from/List
  servers/Map  // From broker-name to ServerConfig (each carries its scope).
  recovery-urls/List

  constructor
      --.path
      --.id
      --.group-pods
      --.is-reference
      --.broker-name
      --.migrating-from
      --.servers
      --.recovery-urls:

  static parse path/string --default-broker-config/ServerConfig --cli/Cli -> FleetFile:
    ui := cli.ui
    fleet-contents := null
    exception := catch: fleet-contents = read-json path
    if exception:
      ui.emit --error "Fleet file '$path' is not a valid JSON."
      ui.emit --error exception.message
      ui.abort
    if fleet-contents is not Map:
      ui.abort "Fleet file '$path' has invalid format."
    if not fleet-contents.contains "id":
      ui.abort "Fleet file '$path' does not contain an ID."

    schema := fleet-contents.get "\$schema"
    if schema and schema != JSON-SCHEMA:
      ui.abort "Fleet file '$path' has an unsupported schema: $schema"
    is-new-format := schema != null

    if not is-new-format and not fleet-contents.contains "organization":
      ui.abort "Fleet file '$path' does not contain an organization ID."

    is-reference := fleet-contents.get "is-reference" --if-absent=: false

    group-entry := fleet-contents.get "groups"
    group-pods/Map := ?
    if is-reference:
      group-pods = {:}
      if group-entry:
        ui.abort "Fleet file '$path' is a reference file and cannot contain a 'groups' entry."
    else:
      if not group-entry:
        ui.abort "Fleet file '$path' does not contain a 'groups' entry."
      if group-entry is not Map:
        ui.abort "Fleet file '$path' has invalid format for 'groups'."
      group-pods = (group-entry as Map).map: | group-name/string entry |
        if entry is not Map:
          ui.abort "Fleet file '$path' has invalid format for group '$group-name'."
        if not entry.contains "pod":
          ui.abort "Fleet file '$path' does not contain a 'pod' entry for group '$group-name'."
        if entry["pod"] is not string:
          ui.abort "Fleet file '$path' has invalid format for 'pod' in group '$group-name'."
        PodReference.parse entry["pod"] --cli=cli

    broker-entry := fleet-contents.get "broker"
    broker-name/string? := null
    if broker-entry and broker-entry is not string:
      ui.abort "Fleet file '$path' has invalid format for 'broker'."
    broker-name = broker-entry

    organization-id/Uuid? := null
    if not is-new-format:
      organization-id = Uuid.parse fleet-contents["organization"]

    migrating-from-entry := fleet-contents.get "migrating-from"
    servers-entry := fleet-contents.get "servers"

    migrating-from/List := []
    servers/Map := ?
    if broker-name:
      if not servers-entry:
        ui.abort "Fleet file '$path' has invalid format for 'broker' and 'servers'."
      if servers-entry is not Map:
        ui.abort "Fleet file '$path' has invalid format for 'servers'."
      broker-server-entry := servers-entry.get broker-name
      if not broker-server-entry:
        ui.abort "Fleet file '$path' does not contain a server entry for broker '$broker-name'."

      servers = servers-entry.map: | server-name/string encoded-server |
        if encoded-server is not Map:
          ui.abort "Fleet file '$path' has invalid format for server '$server-name'."
        ServerConfig.from-json server-name encoded-server
          --der-deserializer=: base64.decode it

      broker-server/ServerConfig := servers[broker-name]
      if is-new-format:
        if not broker-server.scope:
          ui.abort "Fleet file '$path' is missing 'scope' on broker server '$broker-name'."
        organization-id = Uuid.parse broker-server.scope.to-json
      else:
        legacy-scope := Scope "$organization-id"
        servers.map --in-place: | _ server-config/ServerConfig |
          server-config.with --scope=legacy-scope

      if migrating-from-entry:
        if migrating-from-entry is not List:
          ui.abort "Fleet file '$path' has invalid format for 'migrating-from'."
        migrating-from-entry.do: | server-name |
          if server-name is not string:
            ui.abort "Fleet file '$path' has invalid format for 'migrating-from'."
          if not servers.contains server-name:
            ui.abort "Fleet file '$path' does not contain a server entry for migrating-from server '$server-name'."
        migrating-from = migrating-from-entry
    else:
      if migrating-from-entry or servers-entry:
        ui.abort "Fleet file '$path' has invalid format for 'broker', 'migrating-from' and 'servers'."
      broker-name = default-broker-config.name
      legacy-scope := Scope "$organization-id"
      servers = {
        default-broker-config.name: default-broker-config.with --scope=legacy-scope,
      }

    servers.map --in-place: | _ server-config/ServerConfig |
      if server-config is not ServerConfigSupabase:
        server-config
      else:
        supabase-config := server-config as ServerConfigSupabase
        if supabase-config.url == ORIGINAL-SUPABASE-SERVER-URL:
          cli.ui.emit --info
              "Using updated Artemis server URL: $DEFAULT-ARTEMIS-SERVER-CONFIG.url"
          supabase-config.with --url=DEFAULT-ARTEMIS-SERVER-CONFIG.url
        else:
          supabase-config

    recovery-urls := fleet-contents.get "recovery-urls" --if-absent=: []

    return FleetFile
        --path=path
        --id=Uuid.parse fleet-contents["id"]
        --group-pods=group-pods
        --is-reference=is-reference
        --broker-name=broker-name
        --migrating-from=migrating-from
        --servers=servers
        --recovery-urls=recovery-urls

  /** Returns a copy with the supplied legacy values replaced. */
  with -> FleetFile
      --path/string?=null
      --id/Uuid?=null
      --group-pods/Map?=null
      --is-reference/bool?=null
      --broker-name/string?=null
      --migrating-from/List?=null
      --servers/Map?=null
      --recovery-urls/List?=null:
    return FleetFile
        --path=(path or this.path)
        --id=(id or this.id)
        --group-pods=(group-pods or this.group-pods)
        --is-reference=(is-reference or this.is-reference)
        --broker-name=(broker-name or this.broker-name)
        --migrating-from=(migrating-from or this.migrating-from)
        --servers=(servers or this.servers)
        --recovery-urls=(recovery-urls or this.recovery-urls)

  write -> none:
    write-json-to-file --pretty path (to-json_)

  write-reference --path/string -> none:
    write-json-to-file --pretty path (to-json_ --reference)

  to-json_ --reference/bool=false -> Map:
    result := {
      "\$schema": JSON-SCHEMA,
      "id": "$id",
    }
    if reference:
      result["is-reference"] = true
    else:
      groups := {:}
      sorted-keys := group-pods.keys.sort
      if group-pods.contains DEFAULT-GROUP:
        groups[DEFAULT-GROUP] = {
          "pod": group-pods[DEFAULT-GROUP].to-string
        }
      sorted-keys.do: | group-name |
        if group-name == DEFAULT-GROUP: continue.do
        groups[group-name] = {
          "pod": group-pods[group-name].to-string
        }
      result["groups"] = groups

    result["broker"] = broker-name
    if migrating-from and not migrating-from.is-empty:
      result["migrating-from"] = migrating-from
    result["servers"] = servers.map: | server-name/string server-config/ServerConfig |
      server-config.to-json --der-serializer=: base64.encode it
    result["recovery-urls"] = recovery-urls
    return result

/** Reads and writes the legacy `devices.json` representation. */
class DevicesFile:
  path/string
  devices/List

  constructor .path .devices:

  static parse path/string --cli/Cli -> DevicesFile:
    ui := cli.ui

    encoded-devices := null
    exception := catch: encoded-devices = read-json path
    if exception:
      ui.emit --error "Fleet file '$path' is not a valid JSON."
      ui.emit --error exception.message
      ui.abort
    if encoded-devices is not Map:
      ui.abort "Fleet file '$path' has invalid format."

    devices := []
    encoded-devices.do: | device-id encoded-device |
      if encoded-device is not Map:
        ui.abort "Fleet file '$path' has invalid format for device ID $device-id."
      exception = catch:
        device := DeviceFleet
            --id=Uuid.parse device-id
            --name=encoded-device.get "name"
            --aliases=encoded-device.get "aliases"
            --group=(encoded-device.get "group") or DEFAULT-GROUP
        devices.add device
      if exception:
        ui.emit --error "Fleet file '$path' has invalid format for device ID $device-id."
        ui.emit --error exception.message
        ui.abort

    return DevicesFile path devices

  check-groups fleet-file/FleetFile --cli/Cli:
    devices.do: | device/DeviceFleet |
      if not fleet-file.group-pods.contains device.group:
        cli.ui.abort "Device $device.short-string is in group '$device.group' which doesn't exist."

  write -> none:
    sorted-devices := devices.sort: | a/DeviceFleet b/DeviceFleet | a.compare-to b
    encoded-devices := {:}
    sorted-devices.do: | device/DeviceFleet |
      entry := {:}
      if device.name: entry["name"] = device.name
      if not device.aliases.is-empty: entry["aliases"] = device.aliases
      group := device.group
      if group != DEFAULT-GROUP: entry["group"] = group
      encoded-devices["$device.id"] = entry
    write-json-to-file --pretty path encoded-devices

/**
Creates and opens stores backed by the legacy fleet and device JSON files.

The legacy broker configuration is needed only while the combined fleet-file
  reader remains in use. It is not part of the $FleetStore contract.
*/
class FileFleetStoreStrategy implements FleetStoreStrategy:
  static FLEET-FILE ::= "fleet.json"
  static DEVICES-FILE ::= "devices.json"

  root_/string
  legacy-default-broker-config_/ServerConfig
  legacy-initial-recovery-urls_/List
  cli_/Cli

  constructor
      --root/string
      --legacy-default-broker-config/ServerConfig
      --legacy-initial-recovery-urls/List=[]
      --cli/Cli:
    root_ = root
    legacy-default-broker-config_ = legacy-default-broker-config
    legacy-initial-recovery-urls_ = legacy-initial-recovery-urls
    cli_ = cli

  open -> FileFleetStore:
    ui := cli_.ui
    if not file.is-directory root_:
      ui.abort "Fleet root '$root_' is not a directory."
    fleet-path := "$root_/$FLEET-FILE"
    if not file.is-file fleet-path:
      ui.emit --error "Fleet root '$root_' does not contain a $FLEET-FILE file."
      ui.emit --error "Use 'init' to initialize a fleet root."
      ui.abort

    fleet-file := FleetFile.parse fleet-path
        --default-broker-config=legacy-default-broker-config_
        --cli=cli_
    if fleet-file.is-reference:
      ui.abort "Fleet file in given directory is a reference."

    devices-path := "$root_/$DEVICES-FILE"
    if not file.is-file devices-path:
      ui.emit --error "Fleet root '$root_' does not contain a $DEVICES-FILE file."
      ui.emit --error "Use 'init' to initialize a fleet root."
      ui.abort
    devices-file := DevicesFile.parse devices-path --cli=cli_
    devices-file.check-groups fleet-file --cli=cli_

    return FileFleetStore
        --root=root_
        --fleet-file=fleet-file
        --devices-file=devices-file

  /** Opens a temporary access-only legacy fleet reference. */
  open-reference -> LegacyFleetReference:
    ui := cli_.ui
    if not file.is-file root_:
      ui.abort "Fleet reference '$root_' is not a file."
    fleet-file := FleetFile.parse root_
        --default-broker-config=legacy-default-broker-config_
        --cli=cli_
    if not fleet-file.is-reference:
      ui.abort "Provided fleet-file is not a reference."
    return LegacyFleetReference fleet-file

  create -> FileFleetStore
      --id/Uuid
      --group-pods/Map
      --devices/List:
    ui := cli_.ui
    if not file.is-directory root_:
      ui.abort "Fleet root '$root_' is not a directory."
    if file.is-file "$root_/$FLEET-FILE":
      ui.abort "Fleet root '$root_' already contains a $FLEET-FILE file."
    if file.is-file "$root_/$DEVICES-FILE":
      ui.abort "Fleet root '$root_' already contains a $DEVICES-FILE file."

    broker-name := legacy-default-broker-config_.name
    fleet-file := FleetFile
        --path="$root_/$FLEET-FILE"
        --id=id
        --group-pods=group-pods
        --is-reference=false
        --broker-name=broker-name
        --migrating-from=[]
        --servers={broker-name: legacy-default-broker-config_}
        --recovery-urls=legacy-initial-recovery-urls_
    fleet-file.write

    devices-file := DevicesFile "$root_/$DEVICES-FILE" devices
    devices-file.write

    default-specification-path := "$root_/$(INITIAL-POD-NAME).yaml"
    if not file.is-file default-specification-path:
      header := "# yaml-language-server: \$schema=$FleetFile.JSON-SCHEMA\n"
      write-yaml-to-file
          default-specification-path
          INITIAL-POD-SPECIFICATION
          --header=header

    return FileFleetStore
        --root=root_
        --fleet-file=fleet-file
        --devices-file=devices-file

/** Implements $FleetStore using the legacy fleet and device JSON files. */
class FileFleetStore implements FleetStore LegacyFleetWiring:
  static FLEET-FILE ::= FileFleetStoreStrategy.FLEET-FILE
  static DEVICES-FILE ::= FileFleetStoreStrategy.DEVICES-FILE

  root_/string
  fleet-file_/FleetFile := ?
  devices-file_/DevicesFile := ?

  constructor
      --root/string
      --fleet-file/FleetFile
      --devices-file/DevicesFile:
    root_ = root
    fleet-file_ = fleet-file
    devices-file_ = devices-file

  /** Loads the device file in the given legacy fleet directory. */
  static load-devices-file fleet-root/string --cli/Cli -> DevicesFile:
    ui := cli.ui
    if not file.is-directory fleet-root:
      ui.abort "Fleet root '$fleet-root' is not a directory."
    devices-path := "$fleet-root/$DEVICES-FILE"
    if not file.is-file devices-path:
      ui.emit --error "Fleet root '$fleet-root' does not contain a $DEVICES-FILE file."
      ui.emit --error "Use 'init' to initialize a fleet root."
      ui.abort
    return DevicesFile.parse devices-path --cli=cli

  id -> Uuid: return fleet-file_.id
  group-pods -> Map: return fleet-file_.group-pods
  devices -> List: return devices-file_.devices

  save-fleet -> none
      --group-pods/Map?=null:
    fleet-file_ = fleet-file_.with
        --group-pods=group-pods
    fleet-file_.write

  save-devices devices/List -> none:
    devices-file_ = DevicesFile "$root_/$DEVICES-FILE" devices
    devices-file_.write

  broker-name -> string: return fleet-file_.broker-name
  migrating-from -> List: return fleet-file_.migrating-from
  servers -> Map: return fleet-file_.servers
  recovery-urls -> List: return fleet-file_.recovery-urls

  save-wiring -> none
      --broker-name/string?=null
      --migrating-from/List?=null
      --servers/Map?=null
      --recovery-urls/List?=null:
    fleet-file_ = fleet-file_.with
        --broker-name=broker-name
        --migrating-from=migrating-from
        --servers=servers
        --recovery-urls=recovery-urls
    fleet-file_.write

  write-reference --path/string -> none:
    fleet-file_.write-reference --path=path

/** Provides access wiring from a temporary legacy reference file. */
class LegacyFleetReference implements LegacyFleetWiring:
  fleet-file_/FleetFile := ?

  constructor .fleet-file_:

  id -> Uuid: return fleet-file_.id
  broker-name -> string: return fleet-file_.broker-name
  migrating-from -> List: return fleet-file_.migrating-from
  servers -> Map: return fleet-file_.servers
  recovery-urls -> List: return fleet-file_.recovery-urls

  save-wiring -> none
      --broker-name/string?=null
      --migrating-from/List?=null
      --servers/Map?=null
      --recovery-urls/List?=null:
    throw "Cannot change wiring through a legacy fleet reference."

  write-reference --path/string -> none:
    fleet-file_.write-reference --path=path
