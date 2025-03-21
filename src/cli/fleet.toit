// Copyright (C) 2023 Toitware ApS. All rights reserved.

import certificate-roots
import cli show Cli
import encoding.json
import encoding.ubjson
import encoding.base64
import host.file
import uuid show Uuid

import .artemis
import .broker
import .cache
import .config
import .device
import .event
import .firmware
import .pod
import .pod-specification
import .pod-registry
import .utils
import .utils.names
import .server-config
import ..shared.json-diff

DEFAULT-GROUP ::= "default"

class DeviceFleet:
  id/Uuid
  name/string?
  group/string
  aliases/List

  constructor
      --.id
      --.group
      --.name=(random-name --uuid=id)
      --.aliases=[]:

  short-string -> string:
    if name: return "$id ($name)"
    return "$id"

  with --group/string -> DeviceFleet:
    return DeviceFleet
        --id=id
        --group=group
        --name=name
        --aliases=aliases

  compare-to other/DeviceFleet -> int:
    bytes1 := id.to-byte-array
    bytes2 := other.id.to-byte-array
    for i := 0; i < bytes1.size; i++:
      if bytes1[i] < bytes2[i]: return -1
      if bytes1[i] > bytes2[i]: return 1
    return 0

class Status_:
  static CHECKIN-VERIFICATION-COUNT ::= 5
  static UNKNOWN-MISSED-CHECKINS ::= -1
  never-seen/bool
  last-seen/Time?
  is-fully-updated/bool
  /** Number of missed checkins out of $CHECKIN-VERIFICATION-COUNT. */
  missed-checkins/int
  is-modified/bool

  constructor --.never-seen --.is-fully-updated --.missed-checkins --.last-seen --.is-modified:

  is-healthy -> bool:
    return is-fully-updated and missed-checkins == 0

class FleetFile:
  path/string
  id/Uuid
  organization-id/Uuid
  group-pods/Map
  is-reference/bool
  broker-name/string
  migrating-from/List
  servers/Map  // From broker-name to ServerConfig.
  recovery-urls/List

  constructor
      --.path
      --.id
      --.organization-id
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
    if not fleet-contents.contains "organization":
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

    broker-name := fleet-contents.get "broker"
    migrating-from-entry := fleet-contents.get "migrating-from"
    servers-entry := fleet-contents.get "servers"

    migrating-from/List := []
    servers/Map := ?
    if broker-name:
      if not servers-entry:
        ui.abort "Fleet file '$path' has invalid format for 'broker' and 'servers'."
      if servers-entry is not Map:
        ui.abort "Fleet file '$path' has invalid format for 'servers'."
      broker-entry := servers-entry.get broker-name
      if not broker-entry:
        ui.abort "Fleet file '$path' does not contain a server entry for broker '$broker-name'."

      servers = servers-entry.map: | server-name/string encoded-server |
        if encoded-server is not Map:
          ui.abort "Fleet file '$path' has invalid format for server '$server-name'."
        ServerConfig.from-json server-name encoded-server
          --der-deserializer=: base64.decode it

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
      servers = {
        default-broker-config.name: default-broker-config,
      }

    recovery-urls := fleet-contents.get "recovery-urls" --if-absent=: []

    return FleetFile
        --path=path
        --id=Uuid.parse fleet-contents["id"]
        --organization-id=Uuid.parse fleet-contents["organization"]
        --group-pods=group-pods
        --is-reference=is-reference
        --broker-name=broker-name
        --migrating-from=migrating-from
        --servers=servers
        --recovery-urls=recovery-urls

  broker-config -> ServerConfig:
    return servers[broker-name]

  /**
  Creates a new fleet file with the given parameters.

  Mutable objects are *not* copied. Do not modify directly group-pods or servers.

  In order to clear the $migrating-from list, pass an empty list.
  */
  with -> FleetFile
      --path/string?=null
      --id/Uuid?=null
      --organization-id/Uuid?=null
      --group-pods/Map?=null
      --is-reference/bool?=null
      --broker-name/string?=null
      --migrating-from/List?=null
      --servers/Map?=null
      --recovery-urls/List?=null:
    return FleetFile
        --path=(path or this.path)
        --id=(id or this.id)
        --organization-id=(organization-id or this.organization-id)
        --group-pods=(group-pods or this.group-pods)
        --is-reference=(is-reference or this.is-reference)
        --broker-name=(broker-name or this.broker-name)
        --migrating-from=(migrating-from or this.migrating-from)
        --servers=(servers or this.servers)
        --recovery-urls=(recovery-urls or this.recovery-urls)

  write -> none:
    payload := to-json_
    write-json-to-file --pretty path payload

  write-reference --path/string -> none:
    payload := to-json_ --reference
    write-json-to-file --pretty path payload

  to-json_ --reference/bool=false -> Map:
    result := {
      "id": "$id",
      "organization": "$organization-id",
    }
    if reference:
      result["is-reference"] = true
    else:
      groups := {:}
      sorted-keys := group-pods.keys.sort

      // Write the default group at the top.
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

    // Add the servers last, so that the file is easier to read.
    result["broker"] = broker-name
    if migrating-from and not migrating-from.is-empty:
      result["migrating-from"] = migrating-from
    result["servers"] = servers.map: | server-name/string server-config/ServerConfig |
      server-config.to-json --der-serializer=: base64.encode it
    result["recovery-urls"] = recovery-urls
    return result

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
A fleet.

This class, contrary to $FleetWithDevices, can only manipulate the pods of the fleet.
In return, it can be instantiated with only a fleet-reference file.
*/
class Fleet:
  static FLEET-FILE_ ::= "fleet.json"

  id/Uuid
  organization-id/Uuid
  artemis/Artemis
  broker/Broker
  cli_/Cli
  fleet-root-or-ref_/string
  fleet-file_/FleetFile

  constructor fleet-root-or-ref/string
      artemis/Artemis
      --default-broker-config/ServerConfig
      --cli/Cli:
    fleet-file := load-fleet-file fleet-root-or-ref
        --default-broker-config=default-broker-config
        --cli=cli
    return Fleet fleet-root-or-ref artemis
        --fleet-file=fleet-file
        --cli=cli

  constructor .fleet-root-or-ref_ .artemis
      --fleet-file/FleetFile
      --short-strings/Map?=null
      --cli/Cli:
    fleet-file_ = fleet-file
    id = fleet-file.id
    organization-id = fleet-file.organization-id
    cli_ = cli
    broker = Broker
        --server-config=fleet-file.broker-config
        --fleet-id=id
        --organization-id=organization-id
        --tmp-directory=artemis.tmp-directory
        --short-strings=short-strings
        --cli=cli

    // TODO(florian): should we always do this check?
    org := artemis.get-organization --id=organization-id
    if not org:
      cli.ui.abort "Organization $organization-id does not exist or is not accessible."

  static load-fleet-file -> FleetFile
      fleet-root-or-ref/string
      --default-broker-config/ServerConfig
      --cli/Cli:
    ui := cli.ui

    fleet-path/string := ?
    must-be-reference/bool := ?
    if file.is-file fleet-root-or-ref:
      // Must be a reference.
      fleet-path = fleet-root-or-ref
      must-be-reference = true
    else if file.is-directory fleet-root-or-ref:
      fleet-path = "$fleet-root-or-ref/$FLEET-FILE_"
      must-be-reference = false
    else:
      ui.abort "Fleet root '$fleet-root-or-ref' is not a directory or a file."
      unreachable

    if not file.is-file fleet-path:
      // Can only happen if the fleet-root-or-ref was a directory.
      ui.emit --error "Fleet root '$fleet-root-or-ref' does not contain a $FLEET-FILE_ file."
      ui.emit --error "Use 'init' to initialize a fleet root."
      ui.abort

    result := FleetFile.parse fleet-path
        --default-broker-config=default-broker-config
        --cli=cli
    if must-be-reference and not result.is-reference:
      ui.abort "Provided fleet-file is not a reference."
    else if not must-be-reference and result.is-reference:
      ui.abort "Fleet file in given directory is a reference."

    return result

  write-reference --path/string -> none:
    fleet-file_.write-reference --path=path

  /**
  Uploads the given $pod to the broker.

  Also uploads the trivial patches.
  */
  upload --pod/Pod --tags/List --force-tags/bool -> UploadResult:
    cli_.ui.emit --info "Uploading pod. This may take a while."

    return broker.upload
        --pod=pod
        --tags=tags
        --force-tags=force-tags

  download reference/PodReference -> Pod:
    if reference.name and not (reference.tag or reference.revision):
      reference = reference.with --tag="latest"
    pod-id := reference.id
    if not pod-id:
      pod-id = get-pod-id reference
    if not broker.is-cached --pod-id=pod-id:
      cli_.ui.emit --info "Downloading pod '$reference'."
    return download --pod-id=pod-id

  download --pod-id/Uuid -> Pod:
    return broker.download --pod-id=pod-id

  list-pods --names/List -> Map:
    return broker.list-pods --names=names

  delete --description-names/List:
    broker.delete --description-names=description-names

  delete --pod-references/List:
    broker.delete --pod-references=pod-references

  add-tags --tags/List --force/bool --references/List:
    broker.add-tags --tags=tags --force=force --references=references

  remove-tags --tags/List --references/List:
    broker.remove-tags --tags=tags --references=references

  pod pod-id/Uuid -> PodBroker:
    return broker.pod pod-id

  get-pod-id reference/PodReference -> Uuid:
    return broker.get-pod-id reference

  get-pod-id --name/string --tag/string? --revision/int? -> Uuid:
    return broker.get-pod-id --name=name --tag=tag --revision=revision

  pod-exists reference/PodReference -> bool:
    return broker.pod-exists reference

  recovery-urls -> List:
    return fleet-file_.recovery-urls

  recovery-url-add url/string -> none:
    old-urls := fleet-file_.recovery-urls
    if old-urls.contains url:
      cli_.ui.emit --info "Recovery URL '$url' already exists."
      return
    new-urls := old-urls + [url]
    new-file := fleet-file_.with --recovery-urls=new-urls
    new-file.write

  recovery-url-remove url/string -> bool:
    old-urls := fleet-file_.recovery-urls
    new-urls := old-urls.filter: it != url
    if old-urls.size == new-urls.size:
      return false

    new-file := fleet-file_.with --recovery-urls=new-urls
    new-file.write
    return true

  recovery-urls-remove-all -> none:
    new-file := fleet-file_.with --recovery-urls=[]
    new-file.write

  recovery-info -> ByteArray:
    broker.server-config.fill-certificate-ders: certificate-roots.MAP[it].raw
    json-config := broker.server-config.to-service-json
        --base64
        --der-serializer=: unreachable
    return json.encode json-config

/**
A fleet with devices.

Contrary to the $Fleet class, this class needs access to the devices of a fleet.
It can only be instantiated with a non-reference fleet file.
*/
class FleetWithDevices extends Fleet:
  static DEVICES-FILE_ ::= "devices.json"
  static FLEET-FILE_ ::= Fleet.FLEET-FILE_

  /** Signal that an alias is ambiguous. */
  static AMBIGUOUS_ ::= -1

  /** List of $DeviceFleet objects. */
  devices_/List

  /**
  Mapping from device-id to short-name.
  This information is redundant with $devices_, as the $DeviceFleet objects
  contain the same information.
  */
  device-short-strings_/Map

  /** A map from group-name to $PodReference. */
  group-pods_/Map

  /** Map from name, device-id, alias to index in $devices_. */
  aliases_/Map := {:}

  constructor fleet-root/string artemis/Artemis
      --default-broker-config/ServerConfig
      --cli/Cli:
    if not file.is-directory fleet-root and file.is-file fleet-root:
      cli.ui.abort "Fleet argument for this operation must be a fleet root (directory) and not a reference file: '$fleet-root'."

    fleet-file := Fleet.load-fleet-file fleet-root
        --default-broker-config=default-broker-config
        --cli=cli
    if fleet-file.is-reference:
      cli.ui.abort "Fleet root '$fleet-root' is a reference fleet and cannot be used for device management."
    devices-file := load-devices-file fleet-root --cli=cli
    devices-file.check-groups fleet-file --cli=cli
    group-pods_ = fleet-file.group-pods
    devices_ = devices-file.devices
    device-short-strings_ = {:}
    devices_.do: | device/DeviceFleet |
      device-short-strings_[device.id] = device.short-string
    aliases_ = build-alias-map_ devices_ --cli=cli
    super fleet-root artemis
        --fleet-file=fleet-file
        --short-strings=device-short-strings_
        --cli=cli

  static init fleet-root/string artemis/Artemis -> FleetFile
      --organization-id/Uuid
      --broker-config/ServerConfig
      --recovery-url-prefixes/List
      --cli/Cli:
    ui := cli.ui

    if not file.is-directory fleet-root:
      ui.abort "Fleet root '$fleet-root' is not a directory."

    if file.is-file "$fleet-root/$FLEET-FILE_":
      ui.abort "Fleet root '$fleet-root' already contains a $FLEET-FILE_ file."

    if file.is-file "$fleet-root/$DEVICES-FILE_":
      ui.abort "Fleet root '$fleet-root' already contains a $DEVICES-FILE_ file."

    org := artemis.get-organization --id=organization-id
    if not org:
      ui.abort "Organization $organization-id does not exist or is not accessible."

    broker-name := broker-config.name
    fleet-id := random-uuid
    recovery-urls := recovery-url-prefixes.map: | prefix |
      "$prefix/recover-$(fleet-id).json"
    fleet-file := FleetFile
        --path="$fleet-root/$FLEET-FILE_"
        --id=fleet-id
        --organization-id=organization-id
        --group-pods={
          DEFAULT-GROUP: PodReference.parse "$INITIAL-POD-NAME@latest" --cli=cli,
        }
        --is-reference=false
        --broker-name=broker-name
        --migrating-from=[]
        --servers={broker-name: broker-config}
        --recovery-urls=recovery-urls
    fleet-file.write

    devices-file := DevicesFile "$fleet-root/$DEVICES-FILE_" []
    devices-file.write

    default-specification-path := "$fleet-root/$(INITIAL-POD-NAME).yaml"
    if not file.is-file default-specification-path:
      header := "# yaml-language-server: \$schema=$JSON-SCHEMA\n"
      write-yaml-to-file default-specification-path INITIAL-POD-SPECIFICATION --header=header

    return fleet-file

  static load-devices-file fleet-root/string --cli/Cli -> DevicesFile:
    ui := cli.ui
    if not file.is-directory fleet-root:
      ui.abort "Fleet root '$fleet-root' is not a directory."
    devices-path := "$fleet-root/$DEVICES-FILE_"
    if not file.is-file devices-path:
      ui.emit --error "Fleet root '$fleet-root' does not contain a $DEVICES-FILE_ file."
      ui.emit --error "Use 'init' to initialize a fleet root."
      ui.abort

    return DevicesFile.parse devices-path --cli=cli

  /** The root (directory) of this fleet. */
  root -> string:
    // Since this is a fleet with devices, we know that the $fleet-root-or-ref_ must be a
    // directory and not just a ref file.
    return fleet-root-or-ref_

  write-devices_ -> none:
    file := DevicesFile "$fleet-root-or-ref_/$DEVICES-FILE_" devices_
    file.write

  /**
  Builds an alias map.

  When referring to devices we allow names, device-ids and aliases as
    designators. This function builds a map for these and warns the
    user if any of them is ambiguous.
  */
  static build-alias-map_ devices/List --cli/Cli -> Map:
    result := {:}
    ambiguous-ids := {:}
    devices.size.repeat: | index/int |
      device/DeviceFleet := devices[index]
      add-alias := : | id/string |
        if result.contains id:
          old := result[id]
          if old == index:
            // The name, device-id or alias appears twice for the same
            // device. Not best practice, but not ambiguous.
            continue.add-alias

          if old == AMBIGUOUS_:
            ambiguous-ids[id].add index
          else:
            ambiguous-ids[id] = [old, index]
            result[id] = AMBIGUOUS_
        else:
          result[id] = index

      add-alias.call "$device.id"
      if device.name:
        add-alias.call device.name
      device.aliases.do: | alias/string |
        add-alias.call alias
    if ambiguous-ids.size > 0:
      cli.ui.emit --warning "The following names, device-ids or aliases are ambiguous:"
      ambiguous-ids.do: | id/string index-list/List |
        uuid-list := index-list.map: devices[it].id
        cli.ui.emit --warning "  $id maps to $(uuid-list.join ", ")"
    return result

  /**
  Creates a new identity file.

  Returns the path to the identity file.

  It's safe to call this method with a $random-uuid.
  */
  create-identity -> string
      --id/Uuid
      --name/string?=null
      --aliases/List?=null
      --group/string
      --output-directory/string:
    if not has-group group:
      cli_.ui.abort "Group '$group' not found."

    old-size := devices_.size
    new-file := "$output-directory/$(id).identity"

    provision --device-id=id --out-path=new-file

    device := DeviceFleet
        --id=id
        --group=group
        --aliases=aliases
        --name=name
    devices_.add device
    write-devices_

    return new-file

  /**
  Returns the pod for the given $device.
  */
  pod-for device/DeviceFleet -> Pod:
    return download (pod-reference-for-group device.group)

  update --device-id/Uuid --pod/Pod:
    broker.update --device-id=device-id --pod=pod

    // We need to notify the migrating-from brokers.
    fleet-file_.migrating-from.do: | server-name |
      cli_.ui.emit --info "Updating on '$server-name' broker (migration in progress)."
      server-config := fleet-file_.servers.get server-name
      old-broker := Broker
          --server-config=server-config
          --short-strings=device-short-strings_
          --fleet-id=id
          --organization-id=organization-id
          --tmp-directory=artemis.tmp-directory
          --cli=cli_
      old-broker.update --device-id=device-id --pod=pod

  /**
  Rolls out the local configuration to the broker.

  The $diff-bases is a list of pods to build patches against if
    a device hasn't set its state yet.
  */
  roll-out --diff-bases/List:
    ui := cli_.ui

    fleet-devices := devices_
    device-ids := fleet-devices.map: it.id

    detailed-devices := broker.get-devices --device-ids=device-ids
    fleet-devices.do: | fleet-device/DeviceFleet |
      if not detailed-devices.contains fleet-device.id:
        ui.abort "Device $fleet-device.id is unknown to the broker."

    pods-per-group := {:}  // From group-name to Pod.
    pods := fleet-devices.map: | fleet-device/DeviceFleet |
      group-name := fleet-device.group
      pods-per-group.get group-name --init=: download (pod-reference-for-group group-name)

    is-migrating := not fleet-file_.migrating-from.is-empty
    broker.roll-out
        --devices=detailed-devices.values
        --pods=pods
        --diff-bases=diff-bases
        --warn-only-trivial=not is-migrating

    ui.emit --info "Successfully updated $(fleet-devices.size) device$(fleet-devices.size == 1 ? "" : "s")."

    // We need to notify the migrating-from brokers.
    fleet-file_.migrating-from.do: | server-name |
      ui.emit --info "Rolling out to '$server-name' broker (migration in progress)."
      server-config := fleet-file_.servers.get server-name
      old-broker := Broker
          --server-config=server-config
          --short-strings=device-short-strings_
          --fleet-id=id
          --organization-id=organization-id
          --tmp-directory=artemis.tmp-directory
          --cli=cli_
      // We could filter out devices that were already known in the new broker, but
      // it's easier and more robust to update all devices.
      // This also makes it possible to move forward and backward between two brokers.
      detailed-devices = old-broker.get-devices --device-ids=device-ids
      old-broker.roll-out --devices=detailed-devices.values --pods=pods --diff-bases=diff-bases
      ui.emit --info "Successfully rolled out to '$server-name' broker (migration in progress)."

  pod-reference-for-group name/string -> PodReference:
    return group-pods_.get name
        --if-absent=: cli_.ui.abort "Unknown group '$name'"

  has-group group/string -> bool:
    return group-pods_.contains group

  add-device --device-id/Uuid --name/string? --group/string --aliases/List?:
    if aliases and aliases.is-empty: aliases = null
    devices_.add (DeviceFleet --id=device-id --group=group --name=name --aliases=aliases)
    write-devices_

  static build-status_ device/DeviceDetailed get-state-events/List? last-event/Event? -> Status_:
    CHECKIN-VERIFICATIONS ::= 5
    SLACK-FACTOR ::= 0.3
    firmware-state := device.reported-state-firmware
    current-state := device.reported-state-current
    if not firmware-state:
      if not last-event:
        return Status_
            --is-fully-updated=false
            --missed-checkins=Status_.UNKNOWN-MISSED-CHECKINS
            --never-seen=true
            --last-seen=null
            --is-modified=false

      return Status_
          --is-fully-updated=false
          --missed-checkins=Status_.UNKNOWN-MISSED-CHECKINS
          --never-seen=false
          --last-seen=last-event.timestamp
          --is-modified=false

    goal := device.goal
    is-updated/bool := ?
    // TODO(florian): remove the special case of `null` meaning "back to firmware".
    if not goal and not current-state:
      is-updated = true
    else if not goal:
      is-updated = false
    else:
      is-updated = json-equals (current-state or firmware-state) goal
    max-offline-s/int? := (current-state or firmware-state).get "max-offline"
    // If the device has no max_offline, we assume it's 20 seconds.
    // TODO(florian): handle this better.
    if not max-offline-s:
      max-offline-s = 20
    max-offline := Duration --s=max-offline-s

    missed-checkins/int := ?
    if not get-state-events or get-state-events.is-empty:
      missed-checkins = Status_.UNKNOWN-MISSED-CHECKINS
    else:
      slack := max-offline * SLACK-FACTOR
      missed-checkins = 0
      checkin-index := CHECKIN-VERIFICATIONS - 1
      last := Time.now
      earliest-time := last - (max-offline * CHECKIN-VERIFICATIONS)
      for i := 0; i < get-state-events.size; i++:
        event := get-state-events[i]
        event-timestamp := event.timestamp
        if event-timestamp < earliest-time:
          event-timestamp = earliest-time
          // We want to handle this interval, but no need to look at more
          // events.
          i = get-state-events.size
        duration-since-last-checkin := event-timestamp.to last
        missed := (duration-since-last-checkin - slack).in-ms / max-offline.in-ms
        missed-checkins += missed
        last = event.timestamp
    return Status_
        --is-fully-updated=is-updated
        --missed-checkins=missed-checkins
        --never-seen=false
        --last-seen=last-event and last-event.timestamp
        --is-modified=device.reported-state-current != null

  status --include-healthy/bool --include-never-seen/bool:
    fleet-file := fleet-file_
    migrating-from-brokers := fleet-file.migrating-from.map: | name/string |
      config := fleet-file.servers[name]
      Broker
          --server-config=config
          --fleet-id=id
          --organization-id=organization-id
          --short-strings=device-short-strings_
          --cli=cli_
          --tmp-directory=artemis.tmp-directory

    all-brokers := [broker] + migrating-from-brokers

    device-ids := devices_.map: it.id
    id-to-fleet-device := {:}
    devices_.do: | device/DeviceFleet |
      id-to-fleet-device[device.id] = device

    // We use the broker that has the last event for each device.
    has-unmigrated := false
    device-to-broker := {:}
    last-events := {:}
    detailed-devices := {:}

    all-brokers.do: | current-broker/Broker |
      // Get the detailed devices first, as we are not allowed to ask
      // for events of devices the broker doesn't know anything about.
      broker-detailed-devices := current-broker.get-devices --device-ids=device-ids
      // If we don't know anything about the device yet, add it, even if we don't
      // see any event. This happens for devices that have never been seen.
      broker-detailed-devices.do: | device-id/Uuid device/DeviceDetailed |
        if not detailed-devices.contains device-id:
          detailed-devices[device-id] = device
          device-to-broker[device-id] = current-broker

      broker-events := current-broker.get-last-events --device-ids=broker-detailed-devices.keys
      broker-events.do: | device-id/Uuid event/Event |
        old/Event? := last-events.get device-id
        if not old or old.timestamp < event.timestamp:
          last-events[device-id] = event
          device-to-broker[device-id] = current-broker
          detailed-devices[device-id] = broker-detailed-devices[device-id]

    goal-request-events := {:}  // From device-id to List of goal request events.
    pod-entries := {:}  // From broker-name to map of PodRegistryEntry.
    pod-descriptions := {:}  // From broker-name to map of description.
    all-brokers.do: | current-broker/Broker |
      broker-devices := device-to-broker.keys.filter: device-to-broker[it] == current-broker
      if broker-devices.is-empty: continue.do

      if current-broker != broker: has-unmigrated = true

      broker-goal-events := current-broker.get-goal-request-events
          --device-ids=broker-devices
          --limit=Status_.CHECKIN-VERIFICATION-COUNT
      broker-goal-events.do: | device-id/Uuid events/List |
        goal-request-events[device-id] = events

      pod-ids := {}
      broker-devices.do: | device-id/Uuid |
          detailed-device/DeviceDetailed? := detailed-devices.get device-id
          if detailed-device:
            // We might only need the current (and not the firmware), but requesting both
            // descriptions shouldn't hurt.
            if detailed-device.pod-id-current: pod-ids.add detailed-device.pod-id-current
            if detailed-device.pod-id-firmware: pod-ids.add detailed-device.pod-id-firmware

      broker-pod-entry-map := current-broker.get-pod-registry-entry-map --pod-ids=pod-ids.to-list
      pod-entries[current-broker.server-config.name] = broker-pod-entry-map
      broker-description-map := current-broker.get-pod-descriptions
          --pod-registry-entries=broker-pod-entry-map.values
      pod-descriptions[current-broker.server-config.name] = broker-description-map

    rows := []
    device-to-broker.do: | device-id/Uuid broker/Broker |
      broker-name := broker.server-config.name
      fleet-device/DeviceFleet := id-to-fleet-device[device-id]
      detailed-device/DeviceDetailed? := detailed-devices.get device-id
      if not detailed-device:
        cli_.ui.emit --warning "Device $device-id is unknown to the broker."
        continue.do

      status := build-status_ detailed-device
          goal-request-events.get device-id
          last-events.get device-id

      if not include-never-seen and status.never-seen: continue.do

      pod-id/Uuid? := detailed-device.pod-id-current or detailed-device.pod-id-firmware

      if not include-healthy and status.is-healthy: continue.do

      pod-name/string? := null
      pod-revision/int? := null
      pod-tags/List? := null
      pod-description := ""
      if pod-id:
        entry/PodRegistryEntry? := pod-entries[broker-name].get pod-id
        if not entry:
          pod-description = "$pod-id"
        else:
          description/PodRegistryDescription? := pod-descriptions[broker-name].get entry.pod-description-id
          if description:
            pod-name = description.name
            pod-revision = entry.revision
            pod-tags = entry.tags.sort
            pod-description = "$description.name#$entry.revision"
            if not pod-tags.is-empty:
              pod-description += " $(pod-tags.join ",")"
          else:
            pod-description = "$pod-id"

      cross := "x"
      // TODO(florian): when the UI wants structured output we shouldn't change the last
      // seen to human readable.
      human-last-seen := ""
      if status.last-seen:
        human-last-seen = timestamp-to-human-readable status.last-seen
      else if status.never-seen:
        human-last-seen = "never"
      else:
        human-last-seen = "unknown"
      missed-checkins-string := ""
      if status.missed-checkins == Status_.UNKNOWN-MISSED-CHECKINS:
        missed-checkins-string = "?"
      else if status.missed-checkins > 0:
        missed-checkins-string = cross
      row-entry := {
        "device-id": "$device-id",
        "device-name": fleet-device.name or "",
        "pod-id": "$pod-id",
        "pod-name": pod-name,
        "pod-revision": pod-revision,
        "pod-tags": pod-tags,
        "pod-description": pod-description,
        "outdated": not status.is-fully-updated,
        "outdated-human": status.is-fully-updated ? "" : cross,
        "modified": status.is-modified,
        "modified-human": status.is-modified ? cross : "",
        "missed-checkins": status.missed-checkins,
        "missed-checkins-human": missed-checkins-string,
        "last-seen-human": human-last-seen,
        "last-seen": status.last-seen ? "$status.last-seen" : null,
        "never-seen": status.never-seen,
        "aliases": fleet-device.aliases.is-empty ? "" : fleet-device.aliases.join ", ",
        "broker": broker-name,
        // TODO(florian): add more useful information.
      }
      rows.add row-entry

    rows.sort --in-place: | a/Map b/Map |
      a["broker"].compare-to b["broker"] --if-equal=:
        a-pod-name := a["pod-name"] or ""
        b-pod-name := b["pod-name"] or ""
        a-pod-name.compare-to b-pod-name --if-equal=:
          a["device-name"].compare-to b["device-name"] --if-equal=:
            a["device-id"].compare-to b["device-id"]

    header := {
      "device-id": "Device ID",
      "device-name": "Name",
      "pod-description": "Pod",
      "outdated-human": "Outdated",
      "modified-human": "Modified",
      "missed-checkins-human": "Missed Checkins",
      "last-seen-human": "Last Seen",
      "aliases": "Aliases",
    }
    if has-unmigrated:
      header["broker"] = "Broker"
    // TODO(florian): we shouldn't have any `ui.emit --result` outside of `cmd` files.
    cli_.ui.emit-table --result --header=header rows

  resolve-alias alias/string -> DeviceFleet:
    if not aliases_.contains alias:
      cli_.ui.abort "No device with name, device-id, or alias '$alias' in the fleet."
    device-index := aliases_[alias]
    if device-index == AMBIGUOUS_:
      cli_.ui.abort "The name, device-id, or alias '$alias' is ambiguous."
    return devices_[device-index]

  device device-id/Uuid ->  DeviceFleet:
    devices_.do: | device/DeviceFleet |
      if device.id == device-id:
        return device
    cli_.ui.abort "No device with id $device-id in the fleet."
    unreachable

  /**
  Provisions a device.

  Contacts the Artemis server and creates a new device entry with the
    given $device-id (used as "alias" on the server side) in the
    organization with the given $organization-id.

  Writes the identity file to $out-path.
  */
  provision --device-id/Uuid? --out-path/string:
    // Ensure that we are authenticated with both the Artemis server and the broker.
    // We don't want to create a device on Artemis and then have an error with the broker.
    artemis.ensure-authenticated
    broker.ensure-authenticated

    device := artemis.create-device
        --device-id=device-id
        --organization-id=organization-id
    assert: device.id == device-id
    hardware-id := device.hardware-id

    // Insert an initial event mostly for testing purposes.
    artemis.notify-created --hardware-id=hardware-id
    broker.notify-created device

    write-identity-file device --out-path=out-path

  /**
  Writes an identity file.

  This file is used to build a device image and needs to be given to
    $Pod.compute-device-specific-data.
  */
  write-identity-file --out-path/string device/Device -> none:
    write-base64-ubjson-to-file out-path device.to-json-identity

  migration-start --broker-config/ServerConfig:
    // Forward to change the name of the parameter.
    migration-start_ broker-config

  migration-start_ new-broker-config/ServerConfig:
    new-broker := Broker
        --server-config=new-broker-config
        --short-strings=device-short-strings_
        --fleet-id=id
        --organization-id=organization-id
        --tmp-directory=artemis.tmp-directory
        --cli=cli_

    if new-broker.server-config.name == broker.server-config.name:
      // Do nothing. We are already running on this broker.
      return

    detailed-devices := broker.get-devices --device-ids=(devices_.map: it.id)
    new-devices := new-broker.get-devices --device-ids=(devices_.map: it.id)

    detailed-devices.do --values: | device/Device |
      // Only notify the new broker about devices that are not known to it.
      if not new-devices.contains device.id:
        new-broker.notify-created device

    old-servers := fleet-file_.servers
    new-servers := old-servers
    if not old-servers.contains new-broker-config.name:
      new-servers = old-servers.copy
      new-servers[new-broker-config.name] = new-broker-config

    old-migrating-from := fleet-file_.migrating-from
    new-migrating-from := old-migrating-from
    if old-migrating-from.is-empty:
      new-migrating-from = [broker.server-config.name]
    else if not old-migrating-from.contains broker.server-config.name:
      new-migrating-from = old-migrating-from.copy
      new-migrating-from.add broker.server-config.name

    new-migrating-from.filter --in-place: | name/string |
      name != new-broker-config.name

    modified-fleet-file := fleet-file_.with
        --broker-name=new-broker-config.name
        --migrating-from=new-migrating-from
        --servers=new-servers
    modified-fleet-file.write

  migration-stop broker-names/List --force/bool:
    fleet-file := fleet-file_

    if broker-names.is-empty: broker-names = fleet-file.migrating-from

    if not force:
      // Check that all devices have migrated.
      device-ids := devices_.map: it.id
      detailed-devices := broker.get-devices --device-ids=device-ids
      last-events := broker.get-last-events --device-ids=device-ids

      broker-names.do: | name/string |
        current-broker := Broker
            --server-config=fleet-file.servers[name]
            --short-strings=device-short-strings_
            --fleet-id=id
            --organization-id=organization-id
            --tmp-directory=artemis.tmp-directory
            --cli=cli_
        current-detailed-devices := current-broker.get-devices --device-ids=device-ids
        current-ids := current-detailed-devices.keys
        current-last-events := current-broker.get-last-events --device-ids=current-ids
        current-last-events.do: | device-id/Uuid event/Event |
          if not last-events.contains device-id or last-events[device-id].timestamp < event.timestamp:
            devices_.do: | fleet-device/DeviceFleet |
              if fleet-device.id == device-id:
                cli_.ui.abort "Device $fleet-device.short-string has not migrated yet."
            unreachable

    brokers-set := Set
    new-migrating-from := ?
    brokers-set.add-all broker-names
    new-migrating-from = fleet-file.migrating-from.filter: not brokers-set.contains it

    main-broker := fleet-file.broker-name
    new-servers := fleet-file.servers.filter: | name/string _ |
      name == main-broker or not brokers-set.contains name

    modified-fleet-file := fleet-file_.with
        --migrating-from=new-migrating-from
        --servers=new-servers
    modified-fleet-file.write

  static device-from --identity-path/string -> Device:
    identity := read-base64-ubjson identity-path
    device-map := identity["artemis.device"]
    return Device
        --hardware-id=Uuid.parse device-map["hardware_id"]
        --id=Uuid.parse device-map["device_id"]
        --organization-id=Uuid.parse device-map["organization_id"]
