// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import encoding.ubjson
import host.file
import uuid

import .artemis
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

class PodFleet:
  id/uuid.Uuid
  name/string?
  revision/int?
  tags/List?

  constructor --.id --.name --.revision --.tags:

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

  constructor --.path --.id --.organization-id --.group-pods:

  static parse path/string --ui/Ui -> FleetFile:
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

    group-entry := fleet-content.get "groups"
    if not group-entry:
      ui.abort "Fleet file $path does not contain a 'groups' entry."
    if group-entry is not Map:
      ui.abort "Fleet file $path has invalid format for 'groups'."
    group-pods := (group-entry as Map).map: | group-name/string entry |
      if entry is not Map:
        ui.abort "Fleet file $path has invalid format for group '$group-name'."
      if not entry.contains "pod":
        ui.abort "Fleet file $path does not contain a 'pod' entry for group '$group-name'."
      if entry["pod"] is not string:
        ui.abort "Fleet file $path has invalid format for 'pod' in group '$group-name'."
      PodReference.parse entry["pod"] --ui=ui

    return FleetFile
        --path=path
        --id=uuid.parse fleet-content["id"]
        --organization-id=uuid.parse fleet-content["organization"]
        --group-pods=group-pods

  write -> none:
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
    write-json-to-file --pretty path {
      "id": "$id",
      "organization": "$organization-id",
      "groups": groups,
    }

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

class Fleet:
  static DEVICES-FILE_ ::= "devices.json"
  static FLEET-FILE_ ::= "fleet.json"
  /** Signal that an alias is ambiguous. */
  static AMBIGUOUS_ ::= -1

  id/uuid.Uuid
  artemis_/Artemis
  ui_/Ui
  cache_/Cache
  fleet-root_/string
  devices_/List
  organization-id/uuid.Uuid
  /** A map from group-name to $PodReference. */
  group-pods_/Map
  /** Map from name, device-id, alias to index in $devices_. */
  aliases_/Map := {:}

  constructor .fleet-root_ .artemis_ --ui/Ui --cache/Cache --config/Config:
    ui_ = ui
    cache_ = cache
    fleet-file := load-fleet-file fleet-root_ --ui=ui_
    devices-file := load-devices-file fleet-root_ --ui=ui_
    devices-file.check-groups fleet-file --ui=ui_

    id = fleet-file.id
    organization-id = fleet-file.organization-id
    group-pods_ = fleet-file.group-pods
    devices_ = devices-file.devices
    aliases_ = build-alias-map_ devices_ ui

    // TODO(florian): should we always do this check?
    org := artemis_.connected-artemis-server.get-organization organization-id
    if not org:
      ui.abort "Organization $organization-id does not exist or is not accessible."

  static init fleet-root/string artemis/Artemis --organization-id/uuid.Uuid --ui/Ui:
    if not file.is-directory fleet-root:
      ui.abort "Fleet root $fleet-root is not a directory."

    if file.is-file "$fleet-root/$FLEET-FILE_":
      ui.abort "Fleet root $fleet-root already contains a $FLEET-FILE_ file."

    if file.is-file "$fleet-root/$DEVICES-FILE_":
      ui.abort "Fleet root $fleet-root already contains a $DEVICES-FILE_ file."

    org := artemis.connected-artemis-server.get-organization organization-id
    if not org:
      ui.abort "Organization $organization-id does not exist or is not accessible."

    write-json-to-file --pretty "$fleet-root/$FLEET-FILE_" {
      "id": "$random-uuid",
      "organization": "$organization-id",
      "groups": {
        DEFAULT-GROUP: {
          "pod": "$INITIAL-POD-NAME@latest",
        },
      }
    }
    write-json-to-file --pretty "$fleet-root/$DEVICES-FILE_" {:}

    default-specification-path := "$fleet-root/$(INITIAL-POD-NAME).yaml"
    if not file.is-file default-specification-path:
      header := "# yaml-language-server: \$schema=$JSON-SCHEMA\n"
      write-yaml-to-file default-specification-path INITIAL-POD-SPECIFICATION --header=header

    ui.info "Fleet root $fleet-root initialized."

  static load-fleet-file fleet-root/string --ui/Ui -> FleetFile:
    if not file.is-directory fleet-root:
      ui.abort "Fleet root $fleet-root is not a directory."
    fleet-path := "$fleet-root/$FLEET-FILE_"
    if not file.is-file fleet-path:
      ui.error "Fleet root $fleet-root does not contain a $FLEET-FILE_ file."
      ui.error "Use 'init' to initialize a fleet root."
      ui.abort

    return FleetFile.parse fleet-path --ui=ui

  static load-devices-file fleet-root/string --ui/Ui -> DevicesFile:
    if not file.is-directory fleet-root:
      ui.abort "Fleet root $fleet-root is not a directory."
    devices-path := "$fleet-root/$DEVICES-FILE_"
    if not file.is-file devices-path:
      ui.error "Fleet root $fleet-root does not contain a $DEVICES-FILE_ file."
      ui.error "Use 'init' to initialize a fleet root."
      ui.abort

    return DevicesFile.parse devices-path --ui=ui

  write-devices_ -> none:
    file := DevicesFile "$fleet-root_/$DEVICES-FILE_" devices_
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
  */
  create-identity -> string
      --id/uuid.Uuid=random-uuid
      --name/string?=null
      --aliases/List?=null
      --group/string
      --output-directory/string:
    if not has-group group:
      ui_.abort "Group '$group' not found."

    old-size := devices_.size
    new-file := "$output-directory/$(id).identity"

    artemis_.provision
        --device-id=id
        --out-path=new-file
        --organization-id=organization-id

    device := DeviceFleet
        --id=id
        --group=group
        --aliases=aliases
        --name=name
    devices_.add device
    write-devices_

    return new-file

  /**
  Rolls out the local configuration to the broker.

  The $diff-bases is a list of pods to build patches against if
    a device hasn't set its state yet.
  */
  roll-out --diff-bases/List:
    broker := artemis_.connected-broker
    detailed-devices := {:}
    fleet-devices := devices_

    existing-devices := broker.get-devices --device-ids=(fleet-devices.map: it.id)
    fleet-devices.do: | fleet-device/DeviceFleet |
      if not existing-devices.contains fleet-device.id:
        ui_.abort "Device $fleet-device.id is unknown to the broker."

    base-patches := {:}

    base-firmwares := diff-bases.map: | diff-base/Pod |
      FirmwareContent.from-envelope diff-base.envelope-path --cache=cache_

    base-firmwares.do: | content/FirmwareContent |
      trivial-patches := artemis_.extract-trivial-patches content
      trivial-patches.do: | _ patch/FirmwarePatch |
        artemis_.upload-patch patch --organization-id=organization-id

    pods := {:}  // From group-name to Pod.
    fleet-devices.do: | fleet-device/DeviceFleet |
      group-name := fleet-device.group
      if pods.contains group-name: continue.do
      reference := pod-reference-for-group group-name
      pods[group-name] = download reference

    fleet-devices.do: | fleet-device/DeviceFleet |
      artemis_.update
          --device-id=fleet-device.id
          --pod=pods[fleet-device.group]
          --base-firmwares=base-firmwares

      ui_.info "Successfully updated device $fleet-device.short-string."

  /**
  Uploads the given $pod to the broker.

  Also uploads the trivial patches.
  */
  upload --pod/Pod --tags/List --force-tags/bool -> none:
    artemis_.upload --pod=pod --organization-id=organization-id

    broker := artemis_.connected-broker
    pod.split: | manifest/Map parts/Map |
      parts.do: | id/string content/ByteArray |
        // Only upload if we don't have it in our cache.
        key := "$POD-PARTS-PATH/$organization-id/$id"
        cache_.get-file-path key: | store/FileStore |
          broker.pod-registry-upload-pod-part content --part-id=id
              --organization-id=organization-id
          store.save content
      key := "$POD-MANIFEST-PATH/$organization-id/$pod.id"
      cache_.get-file-path key: | store/FileStore |
        encoded := ubjson.encode manifest
        broker.pod-registry-upload-pod-manifest encoded --pod-id=pod.id
            --organization-id=organization-id
        store.save encoded

    description-ids := broker.pod-registry-descriptions
        --fleet-id=this.id
        --organization-id=this.organization-id
        --names=[pod.name]
        --create-if-absent

    description-id := (description-ids[0] as PodRegistryDescription).id

    broker.pod-registry-add
        --pod-description-id=description-id
        --pod-id=pod.id

    is-existing-tag-error := : | error |
      error is string and
        (error.contains "duplicate key value" or error.contains "already exists")

    tag-errors := []
    tags.do: | tag/string |
      force := force-tags or (tag == "latest")
      exception := catch --unwind=(: not is-existing-tag-error.call it):
        broker.pod-registry-tag-set
            --pod-description-id=description-id
            --pod-id=pod.id
            --tag=tag
            --force=force
      if exception:
        tag-errors.add "Tag '$tag' already exists for pod $pod.name."

    registered-pods := broker.pod-registry-pods --fleet-id=this.id --pod-ids=[pod.id]
    pod-entry/PodRegistryEntry := registered-pods[0]

    prefix := tag-errors.is-empty ? "Successfully uploaded" : "Uploaded"
    ui_.info "$prefix $pod.name#$pod-entry.revision to fleet $this.id."
    ui_.info "  id: $pod-entry.id"
    ui_.info "  references:"
    sorted-uploaded-tags := pod-entry.tags.sort
    sorted-uploaded-tags.do: ui_.info "    - $pod.name@$it"

    if not tag-errors.is-empty:
      tag-errors.do: ui_.error it
      ui_.abort

  download reference/PodReference -> Pod:
    if reference.name and not (reference.tag or reference.revision):
      reference = reference.with --tag="latest"
    pod-id := reference.id
    if not pod-id:
      pod-id = get-pod-id reference
    return download --pod-id=pod-id

  download --pod-id/uuid.Uuid -> Pod:
    broker := artemis_.connected-broker
    manifest-key := "$POD-MANIFEST-PATH/$organization-id/$pod-id"
    encoded-manifest := cache_.get manifest-key: | store/FileStore |
      bytes := broker.pod-registry-download-pod-manifest
        --pod-id=pod-id
        --organization-id=this.organization-id
      store.save bytes
    manifest := ubjson.decode encoded-manifest
    return Pod.from-manifest
        manifest
        --tmp-directory=artemis_.tmp-directory
        --download=: | part-id/string |
          key := "$POD-PARTS-PATH/$organization-id/$part-id"
          cache_.get key: | store/FileStore |
            bytes := broker.pod-registry-download-pod-part
                part-id
                --organization-id=this.organization-id
            store.save bytes

  list-pods --names/List -> Map:
    broker := artemis_.connected-broker
    descriptions := ?
    if names.is-empty:
      descriptions = broker.pod-registry-descriptions --fleet-id=this.id
    else:
      descriptions = broker.pod-registry-descriptions
          --fleet-id=this.id
          --organization-id=this.organization-id
          --names=names
          --no-create-if-absent
    result := {:}
    descriptions.do: | description/PodRegistryDescription |
      pods := broker.pod-registry-pods --pod-description-id=description.id
      result[description] = pods
    return result

  delete --description-names/List:
    broker := artemis_.connected-broker
    descriptions := broker.pod-registry-descriptions
        --fleet-id=this.id
        --organization-id=this.organization-id
        --names=description-names
        --no-create-if-absent
    unknown-pod-descriptions := []
    description-names.do: | name/string |
      was-found := descriptions.any: | description/PodRegistryDescription |
        description.name == name
      if not was-found: unknown-pod-descriptions.add name
    if not unknown-pod-descriptions.is-empty:
      if unknown-pod-descriptions.size == 1:
        ui_.abort "Unknown pod $(unknown-pod-descriptions[0])."
      else:
        ui_.abort "Unknown pods $(unknown-pod-descriptions.join ", ")."
    broker.pod-registry-descriptions-delete
        --fleet-id=this.id
        --description-ids=descriptions.map: it.id

  delete --pod-references/List:
    broker := artemis_.connected-broker
    pod-ids := get-pod-ids pod-references
    broker.pod-registry-delete
        --fleet-id=this.id
        --pod-ids=pod-ids

  pod-reference-for-group name/string -> PodReference:
    return group-pods_.get name
        --if-absent=: ui_.abort "Unknown group $name"

  has-group group/string -> bool:
    return group-pods_.contains group

  add-device --device-id/uuid.Uuid --name/string? --group/string --aliases/List?:
    if aliases and aliases.is-empty: aliases = null
    devices_.add (DeviceFleet --id=device-id --group=group --name=name --aliases=aliases)
    write-devices_

  build-status_ device/DeviceDetailed get-state-events/List? last-event/Event? -> Status_:
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
      is-updated = json-equals firmware-state goal
    max-offline-s/int? := firmware-state.get "max-offline"
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
    broker := artemis_.connected-broker
    device-ids := devices_.map: it.id
    detailed-devices := broker.get-devices --device-ids=device-ids
    get-state-events := broker.get-events
        --device-ids=device-ids
        --limit=Status_.CHECKIN-VERIFICATION-COUNT
        --types=["get-goal"]
    last-events := broker.get-events --device-ids=device-ids --limit=1

    pod-ids := []
    devices_.do: | fleet-device/DeviceFleet |
      device/DeviceDetailed? := detailed-devices.get fleet-device.id
      if not device:
        ui_.abort "Device $fleet-device.id is unknown to the broker."
      pod-id := device.pod-id-current or device.pod-id-firmware
      // Add nulls as well.
      pod-ids.add pod-id

    pod-id-entries := broker.pod-registry-pods
        --fleet-id=this.id
        --pod-ids=(pod-ids.filter: it != null)
    pod-entry-map := {:}
    pod-id-entries.do: | entry/PodRegistryEntry |
      pod-entry-map[entry.id] = entry
    description-set := {}
    description-set.add-all
        (pod-id-entries.map: | entry/PodRegistryEntry | entry.pod-description-id)
    description-ids := []
    description-ids.add-all description-set
    descriptions := broker.pod-registry-descriptions --ids=description-ids
    description-map := {:}
    descriptions.do: | description/PodRegistryDescription |
      description-map[description.id] = description

    now := Time.now
    statuses := devices_.map: | fleet-device/DeviceFleet |
      device/DeviceDetailed? := detailed-devices.get fleet-device.id
      if not device:
        ui_.abort "Device $fleet-device.id is unknown to the broker."
      last-events-of-device := last-events.get fleet-device.id
      last-event := last-events-of-device and not last-events-of-device.is-empty
          ? last-events-of-device[0]
          : null
      build-status_ device (get-state-events.get fleet-device.id) last-event

    rows := []
    for i := 0; i < devices_.size; i++:
      fleet-device/DeviceFleet := devices_[i]
      pod-id/uuid.Uuid? := pod-ids[i]
      status/Status_ := statuses[i]
      if not include-healthy and status.is-healthy: continue
      if not include-never-seen and status.never-seen: continue

      pod-name/string? := null
      pod-revision/int? := null
      pod-tags/List? := null
      pod-description := ""
      if pod-id:
        entry/PodRegistryEntry? := pod-entry-map.get pod-id
        if not entry:
          pod-description = "$pod-id"
        else:
          description/PodRegistryDescription := description-map.get entry.pod-description-id
          pod-name = description.name
          pod-revision = entry.revision
          pod-tags = entry.tags
          pod-description = "$description.name#$entry.revision"
          if not entry.tags.is-empty:
            pod-description += " $(entry.tags.join ",")"

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
      rows.add {
        "device-id": "$fleet-device.id",
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
        // TODO(florian): add more useful information.
      }

    rows.sort --in-place: | a/Map b/Map |
      a-pod-name := a["pod-name"] or ""
      b-pod-name := b["pod-name"] or ""
      a-pod-name.compare-to b-pod-name --if-equal=:
        a["device-name"].compare-to b["device-name"] --if-equal=:
          a["device-id"].compare-to b["device-id"]

    // TODO(florian): we shouldn't have any `ui_.result` outside of `cmd` files.
    ui_.do --kind=Ui.RESULT: | printer/Printer |
      printer.emit
          rows
          --header={
            "device-id": "Device ID",
            "device-name": "Name",
            "pod-description": "Pod",
            "outdated-human": "Outdated",
            "modified-human": "Modified",
            "missed-checkins-human": "Missed Checkins",
            "last-seen-human": "Last Seen",
            "aliases": "Aliases",
          }

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

  pod pod-id/uuid.Uuid -> PodFleet:
    broker := artemis_.connected-broker
    pod-entry := broker.pod-registry-pods
        --fleet-id=this.id
        --pod-ids=[pod-id]
    if not pod-entry.is-empty:
      description-id := pod-entry[0].pod-description-id
      description := broker.pod-registry-descriptions --ids=[description-id]
      if not description.is-empty:
        return PodFleet --id=pod-id --name=description[0].name --revision=pod-entry[0].revision --tags=pod-entry[0].tags

    return PodFleet --id=pod-id --name=null --revision=null --tags=null

  get-pod-id reference/PodReference -> uuid.Uuid:
    return (get-pod-ids [reference])[0]

  get-pod-ids references/List -> List:
    references.do: | reference/PodReference |
      if not reference.id:
        if not reference.name:
          throw "Either id or name must be specified: $reference"
        if not reference.tag and not reference.revision:
          throw "Either tag or revision must be specified: $reference"

    missing-ids := references.filter: | reference/PodReference |
      not reference.id
    broker := artemis_.connected-broker
    pod-ids-response := broker.pod-registry-pod-ids --fleet-id=this.id --references=missing-ids

    has-errors := false
    result := references.map: | reference/PodReference |
      if reference.id: continue.map reference.id
      resolved := pod-ids-response.get reference
      if not resolved:
        has-errors = true
        if reference.tag:
          ui_.error "No pod with name $reference.name and tag $reference.tag in the fleet."
        else:
          ui_.error "No pod with name $reference.name and revision $reference.revision in the fleet."
      resolved
    if has-errors: ui_.abort
    return result

  get-pod-id --name/string --tag/string? --revision/int? -> uuid.Uuid:
    return get-pod-id (PodReference --name=name --tag=tag --revision=revision)

  pod-exists reference/PodReference -> bool:
    broker := artemis_.connected-broker
    pod-id := get-pod-id reference
    pod-entry := broker.pod-registry-pods
        --fleet-id=this.id
        --pod-ids=[pod-id]
    return not pod-entry.is-empty
