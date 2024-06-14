// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import encoding.ubjson
import encoding.base64
import host.file
import uuid

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
import .ui
import .utils
import .utils.names
import .server-config
import ..shared.json-diff

DEFAULT-GROUP ::= "default"

class DeviceFleet:
  id/uuid.Uuid
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
  id/uuid.Uuid
  organization-id/uuid.Uuid
  group-pods/Map
  is-reference/bool
  broker-name/string
  migrating-from/List
  servers/Map  // From broker-name to ServerConfig.

  constructor
      --.path
      --.id
      --.organization-id
      --.group-pods
      --.is-reference
      --.broker-name
      --.migrating-from
      --.servers:

  static parse path/string --default-broker-config/ServerConfig --ui/Ui -> FleetFile:
    fleet-content := null
    exception := catch: fleet-content = read-json path
    if exception:
      ui.error "Fleet file $path is not a valid JSON."
      ui.error exception.message
      ui.abort
    if fleet-content is not Map:
      ui.abort "Fleet file $path has invalid format."
    if not fleet-content.contains "id":
      ui.abort "Fleet file $path does not contain an ID."
    if not fleet-content.contains "organization":
      ui.abort "Fleet file $path does not contain an organization ID."

    is-reference := fleet-content.get "is-reference" --if-absent=: false

    group-entry := fleet-content.get "groups"
    group-pods/Map := ?
    if is-reference:
      group-pods = {:}
      if group-entry:
        ui.abort "Fleet file $path is a reference file and cannot contain a 'groups' entry."
    else:
      if not group-entry:
        ui.abort "Fleet file $path does not contain a 'groups' entry."
      if group-entry is not Map:
        ui.abort "Fleet file $path has invalid format for 'groups'."
      group-pods = (group-entry as Map).map: | group-name/string entry |
        if entry is not Map:
          ui.abort "Fleet file $path has invalid format for group '$group-name'."
        if not entry.contains "pod":
          ui.abort "Fleet file $path does not contain a 'pod' entry for group '$group-name'."
        if entry["pod"] is not string:
          ui.abort "Fleet file $path has invalid format for 'pod' in group '$group-name'."
        PodReference.parse entry["pod"] --ui=ui

    broker-name := fleet-content.get "broker"
    migrating-from-entry := fleet-content.get "migrating-from"
    servers-entry := fleet-content.get "servers"

    migrating-from/List := []
    servers/Map := ?
    if broker-name:
      if not servers-entry:
        ui.abort "Fleet file $path has invalid format for 'broker' and 'servers'."
      if servers-entry is not Map:
        ui.abort "Fleet file $path has invalid format for 'servers'."
      broker-entry := servers-entry.get broker-name
      if not broker-entry:
        ui.abort "Fleet file $path does not contain a server entry for broker '$broker-name'."

      servers = servers-entry.map: | server-name/string encoded-server |
        if encoded-server is not Map:
          ui.abort "Fleet file $path has invalid format for server '$server-name'."
        ServerConfig.from-json server-name encoded-server
          --der-deserializer=: base64.decode it

      if migrating-from-entry:
        if migrating-from-entry is not List:
          ui.abort "Fleet file $path has invalid format for 'migrating-from'."
        migrating-from-entry.do: | server-name |
          if server-name is not string:
            ui.abort "Fleet file $path has invalid format for 'migrating-from'."
          if not servers.contains server-name:
            ui.abort "Fleet file $path does not contain a server entry for migrating-from server '$server-name'."
        migrating-from = migrating-from-entry
    else:
      if migrating-from-entry or servers-entry:
        ui.abort "Fleet file $path has invalid format for 'broker', 'migrating-from' and 'servers'."
      broker-name = default-broker-config.name
      servers = {
        default-broker-config.name: default-broker-config,
      }

    return FleetFile
        --path=path
        --id=uuid.parse fleet-content["id"]
        --organization-id=uuid.parse fleet-content["organization"]
        --group-pods=group-pods
        --is-reference=is-reference
        --broker-name=broker-name
        --migrating-from=migrating-from
        --servers=servers

  broker-config -> ServerConfig:
    return servers[broker-name]

  /**
  Creates a new fleet file with the given parameters.

  Mutable objects are *not* copied. Do not modify directly group-pods or servers.

  In order to clear the $migrating-from list, pass an empty list.
  */
  with -> FleetFile
      --path/string?=null
      --id/uuid.Uuid?=null
      --organization-id/uuid.Uuid?=null
      --group-pods/Map?=null
      --is-reference/bool?=null
      --broker-name/string?=null
      --migrating-from/List?=null
      --servers/Map?=null:
    return FleetFile
        --path=(path or this.path)
        --id=(id or this.id)
        --organization-id=(organization-id or this.organization-id)
        --group-pods=(group-pods or this.group-pods)
        --is-reference=(is-reference or this.is-reference)
        --broker-name=(broker-name or this.broker-name)
        --migrating-from=(migrating-from or this.migrating-from)
        --servers=(servers or this.servers)

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
    return result

class DevicesFile:
  path/string
  devices/List

  constructor .path .devices:

  static parse path/string --ui/Ui -> DevicesFile:
    encoded-devices := null
    exception := catch: encoded-devices = read-json path
    if exception:
      ui.error "Fleet file $path is not a valid JSON."
      ui.error exception.message
      ui.abort
    if encoded-devices is not Map:
      ui.abort "Fleet file $path has invalid format."

    devices := []
    encoded-devices.do: | device-id encoded-device |
      if encoded-device is not Map:
        ui.abort "Fleet file $path has invalid format for device ID $device-id."
      exception = catch:
        device := DeviceFleet
            --id=uuid.parse device-id
            --name=encoded-device.get "name"
            --aliases=encoded-device.get "aliases"
            --group=(encoded-device.get "group") or DEFAULT-GROUP
        devices.add device
      if exception:
        ui.error "Fleet file $path has invalid format for device ID $device-id."
        ui.error exception.message
        ui.abort

    return DevicesFile path devices

  check-groups fleet-file/FleetFile --ui/Ui:
    devices.do: | device/DeviceFleet |
      if not fleet-file.group-pods.contains device.group:
        ui.abort "Device $device.short-string is in group '$device.group' which doesn't exist."

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

  id/uuid.Uuid
  organization-id/uuid.Uuid
  artemis/Artemis
  broker/Broker
  ui_/Ui
  cache_/Cache
  config_/Config
  fleet-root-or-ref_/string
  fleet-file_/FleetFile

  constructor fleet-root-or-ref/string
      artemis/Artemis
      --default-broker-config/ServerConfig
      --ui/Ui
      --cache/Cache
      --config/Config:
    fleet-file := load-fleet-file fleet-root-or-ref
        --default-broker-config=default-broker-config
        --ui=ui
    return Fleet fleet-root-or-ref artemis
        --fleet-file=fleet-file
        --ui=ui
        --cache=cache
        --config=config

  constructor .fleet-root-or-ref_ .artemis
      --fleet-file/FleetFile
      --ui/Ui
      --cache/Cache
      --config/Config:
    fleet-file_ = fleet-file
    id = fleet-file.id
    organization-id = fleet-file.organization-id
    ui_ = ui
    cache_ = cache
    config_ = config
    broker = Broker
        --server-config=fleet-file.broker-config
        --cache=cache
        --config=config
        --ui=ui
        --fleet-id=id
        --organization-id=organization-id
        --tmp-directory=artemis.tmp-directory

    // TODO(florian): should we always do this check?
    org := artemis.get-organization --id=organization-id
    if not org:
      ui.abort "Organization $organization-id does not exist or is not accessible."

  static load-fleet-file -> FleetFile
      fleet-root-or-ref/string
      --default-broker-config/ServerConfig
      --ui/Ui:
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
      ui.abort "Fleet root $fleet-root-or-ref is not a directory or a file."
      unreachable

    if not file.is-file fleet-path:
      // Can only happen if the fleet-root-or-ref was a directory.
      ui.error "Fleet root $fleet-root-or-ref does not contain a $FLEET-FILE_ file."
      ui.error "Use 'init' to initialize a fleet root."
      ui.abort

    result := FleetFile.parse fleet-path
        --default-broker-config=default-broker-config
        --ui=ui
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
    ui_.info "Uploading pod. This may take a while."

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
    return download --pod-id=pod-id

  download --pod-id/uuid.Uuid -> Pod:
    return broker.download --pod-id=pod-id

  list-pods --names/List -> Map:
    return broker.list-pods --names=names

  delete --description-names/List:
    broker.delete --description-names=description-names

  delete --pod-references/List:
    broker.delete --pod-references=pod-references

  pod pod-id/uuid.Uuid -> PodBroker:
    return broker.pod pod-id

  get-pod-id reference/PodReference -> uuid.Uuid:
    return broker.get-pod-id reference

  get-pod-id --name/string --tag/string? --revision/int? -> uuid.Uuid:
    return broker.get-pod-id --name=name --tag=tag --revision=revision

  pod-exists reference/PodReference -> bool:
    return broker.pod-exists reference

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
  /** A map from group-name to $PodReference. */
  group-pods_/Map
  /** Map from name, device-id, alias to index in $devices_. */
  aliases_/Map := {:}

  constructor fleet-root/string artemis/Artemis
      --default-broker-config/ServerConfig
      --ui/Ui
      --cache/Cache
      --config/Config:
    if not file.is-directory fleet-root and file.is-file fleet-root:
      ui.abort "Fleet argument for this operation must be a fleet root (directory) and not a reference file: '$fleet-root'."

    fleet-file := Fleet.load-fleet-file fleet-root
        --default-broker-config=default-broker-config
        --ui=ui
    if fleet-file.is-reference:
      ui.abort "Fleet root $fleet-root is a reference fleet and cannot be used for device management."
    devices-file := load-devices-file fleet-root --ui=ui
    devices-file.check-groups fleet-file --ui=ui
    group-pods_ = fleet-file.group-pods
    devices_ = devices-file.devices
    aliases_ = build-alias-map_ devices_ ui
    super fleet-root artemis
        --fleet-file=fleet-file
        --ui=ui
        --cache=cache
        --config=config

  static init fleet-root/string artemis/Artemis
      --organization-id/uuid.Uuid
      --broker-config/ServerConfig
      --ui/Ui:
    if not file.is-directory fleet-root:
      ui.abort "Fleet root $fleet-root is not a directory."

    if file.is-file "$fleet-root/$FLEET-FILE_":
      ui.abort "Fleet root $fleet-root already contains a $FLEET-FILE_ file."

    if file.is-file "$fleet-root/$DEVICES-FILE_":
      ui.abort "Fleet root $fleet-root already contains a $DEVICES-FILE_ file."

    org := artemis.get-organization --id=organization-id
    if not org:
      ui.abort "Organization $organization-id does not exist or is not accessible."

    broker-name := broker-config.name
    fleet-file := FleetFile
        --path="$fleet-root/$FLEET-FILE_"
        --id=random-uuid
        --organization-id=organization-id
        --group-pods={
          DEFAULT-GROUP: PodReference.parse "$INITIAL-POD-NAME@latest" --ui=ui,
        }
        --is-reference=false
        --broker-name=broker-name
        --migrating-from=[]
        --servers={broker-name: broker-config}
    fleet-file.write

    devices-file := DevicesFile "$fleet-root/$DEVICES-FILE_" []
    devices-file.write

    default-specification-path := "$fleet-root/$(INITIAL-POD-NAME).yaml"
    if not file.is-file default-specification-path:
      header := "# yaml-language-server: \$schema=$JSON-SCHEMA\n"
      write-yaml-to-file default-specification-path INITIAL-POD-SPECIFICATION --header=header

    ui.info "Fleet root $fleet-root initialized."

  static load-devices-file fleet-root/string --ui/Ui -> DevicesFile:
    if not file.is-directory fleet-root:
      ui.abort "Fleet root $fleet-root is not a directory."
    devices-path := "$fleet-root/$DEVICES-FILE_"
    if not file.is-file devices-path:
      ui.error "Fleet root $fleet-root does not contain a $DEVICES-FILE_ file."
      ui.error "Use 'init' to initialize a fleet root."
      ui.abort

    return DevicesFile.parse devices-path --ui=ui

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
  static build-alias-map_ devices/List ui/Ui -> Map:
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
      ui.warning "The following names, device-ids or aliases are ambiguous:"
      ambiguous-ids.do: | id/string index-list/List |
        uuid-list := index-list.map: devices[it].id
        ui.warning "  $id maps to $(uuid-list.join ", ")"
    return result

  /**
  Creates a new identity file.

  Returns the path to the identity file.

  It's safe to call this method with a $random-uuid.
  */
  create-identity -> string
      --id/uuid.Uuid
      --name/string?=null
      --aliases/List?=null
      --group/string
      --output-directory/string:
    if not has-group group:
      ui_.abort "Group '$group' not found."

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

  /**
  Rolls out the local configuration to the broker.

  The $diff-bases is a list of pods to build patches against if
    a device hasn't set its state yet.
  */
  roll-out --diff-bases/List:
    fleet-devices := devices_
    device-ids := fleet-devices.map: it.id

    detailed-devices := broker.get-devices --device-ids=device-ids
    fleet-devices.do: | fleet-device/DeviceFleet |
      if not detailed-devices.contains fleet-device.id:
        ui_.abort "Device $fleet-device.id is unknown to the broker."

    pods-per-group := {:}  // From group-name to Pod.
    pods := fleet-devices.map: | fleet-device/DeviceFleet |
      group-name := fleet-device.group
      pods-per-group.get group-name --init=: download (pod-reference-for-group group-name)

    broker.roll-out --devices=detailed-devices.values --pods=pods --diff-bases=diff-bases

    ui_.info "Successfully updated $(fleet-devices.size) device$(fleet-devices.size == 1 ? "" : "s")."

    // We need to notify the migrating-from brokers.
    fleet-file_.migrating-from.do: | server-name |
      ui_.info "Rolling out to $server-name broker (migration in progress)."
      server-config := fleet-file_.servers.get server-name
      old-broker := Broker
          --server-config=server-config
          --cache=cache_
          --config=config_
          --ui=ui_
          --fleet-id=id
          --organization-id=organization-id
          --tmp-directory=artemis.tmp-directory
      // We could filter out devices that were already known in the new broker, but
      // it's easier and more robust to update all devices.
      // This also makes it possible to move forward and backward between two brokers.
      detailed-devices = old-broker.get-devices --device-ids=device-ids
      old-broker.roll-out --devices=detailed-devices.values --pods=pods --diff-bases=diff-bases
      ui_.info "Successfully rolled out to $server-name broker (migration in progress)."

  pod-reference-for-group name/string -> PodReference:
    return group-pods_.get name
        --if-absent=: ui_.abort "Unknown group $name"

  has-group group/string -> bool:
    return group-pods_.contains group

  add-device --device-id/uuid.Uuid --name/string? --group/string --aliases/List?:
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
          --cache=cache_
          --config=config_
          --ui=ui_
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
      broker-detailed-devices.do: | device-id/uuid.Uuid device/DeviceDetailed |
        if not detailed-devices.contains device-id:
          detailed-devices[device-id] = device
          device-to-broker[device-id] = current-broker

      broker-events := current-broker.get-last-events --device-ids=broker-detailed-devices.keys
      broker-events.do: | device-id/uuid.Uuid event/Event |
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
      broker-goal-events.do: | device-id/uuid.Uuid events/List |
        goal-request-events[device-id] = events

      pod-ids := {}
      broker-devices.do: | device-id/uuid.Uuid |
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
    device-to-broker.do: | device-id/uuid.Uuid broker/Broker |
      broker-name := broker.server-config.name
      fleet-device/DeviceFleet := id-to-fleet-device[device-id]
      detailed-device/DeviceDetailed? := detailed-devices.get device-id
      if not detailed-device:
        ui_.warning "Device $device-id is unknown to the broker."
        continue.do

      status := build-status_ detailed-device
          goal-request-events.get device-id
          last-events.get device-id

      if not include-never-seen and status.never-seen: continue.do

      pod-id/uuid.Uuid? := detailed-device.pod-id-current or detailed-device.pod-id-firmware

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

    // TODO(florian): we shouldn't have any `ui_.result` outside of `cmd` files.
    ui_.do --kind=Ui.RESULT: | printer/Printer |
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
      printer.emit rows --header=header

  resolve-alias alias/string -> DeviceFleet:
    if not aliases_.contains alias:
      ui_.abort "No device with name, device-id, or alias $alias in the fleet."
    device-index := aliases_[alias]
    if device-index == AMBIGUOUS_:
      ui_.abort "The name, device-id, or alias $alias is ambiguous."
    return devices_[device-index]

  device device-id/uuid.Uuid ->  DeviceFleet:
    devices_.do: | device/DeviceFleet |
      if device.id == device-id:
        return device
    ui_.abort "No device with id $device-id in the fleet."
    unreachable

  /**
  Provisions a device.

  Contacts the Artemis server and creates a new device entry with the
    given $device-id (used as "alias" on the server side) in the
    organization with the given $organization-id.

  Writes the identity file to $out-path.
  */
  provision --device-id/uuid.Uuid? --out-path/string:
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

    write-identity-file
        --out-path=out-path
        --device-id=device-id
        --hardware-id=hardware-id

  /**
  Writes an identity file.

  This file is used to build a device image and needs to be given to
    $Pod.compute-device-specific-data.
  */
  write-identity-file -> none
      --out-path/string
      --device-id/uuid.Uuid
      --hardware-id/uuid.Uuid:
    // A map from id to DER certificates.
    der-certificates := {:}

    broker-json := server-config-to-service-json broker.server-config der-certificates
    artemis-json := server-config-to-service-json artemis.server-config der-certificates

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

  migration-start --broker-config/ServerConfig:
    // Forward to change the name of the parameter.
    migration-start_ broker-config

  migration-start_ new-broker-config/ServerConfig:
    new-broker := Broker
        --server-config=new-broker-config
        --cache=cache_
        --config=config_
        --ui=ui_
        --fleet-id=id
        --organization-id=organization-id
        --tmp-directory=artemis.tmp-directory

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
    if not old-migrating-from:
      new-migrating-from = [broker.server-config.name]
    else if not old-migrating-from.contains broker.server-config.name:
      new-migrating-from = old-migrating-from.copy
      new-migrating-from.add broker.server-config.name

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
            --cache=cache_
            --config=config_
            --ui=ui_
            --fleet-id=id
            --organization-id=organization-id
            --tmp-directory=artemis.tmp-directory
        current-detailed-devices := current-broker.get-devices --device-ids=device-ids
        current-ids := current-detailed-devices.keys
        current-last-events := current-broker.get-last-events --device-ids=current-ids
        current-last-events.do: | device-id/uuid.Uuid event/Event |
          if not last-events.contains device-id or last-events[device-id].timestamp < event.timestamp:
            devices_.do: | fleet-device/DeviceFleet |
              if fleet-device.id == device-id:
                ui_.abort "Device $fleet-device.short-string has not migrated yet."
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
        --hardware-id=uuid.parse device-map["hardware_id"]
        --id=uuid.parse device-map["device_id"]
        --organization-id=uuid.parse device-map["organization_id"]
