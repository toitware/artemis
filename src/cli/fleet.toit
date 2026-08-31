// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show Cli
import encoding.json
import encoding.ubjson
import uuid show Uuid

import .artemis
import .broker
import .cache
import .device
import .event
import .firmware
import .fleet-store
import .pod
import .pod-specification
import .pod-registry
import .utils
import ..shared.scope show Scope
import .utils.names
import .server-config
import ..shared.json-diff
import ..shared.device-config show DEFAULT-MAX-OFFLINE

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

/** Represents complete declared fleet state. */
class Fleet:
  static AMBIGUOUS_ ::= -1

  store/FleetStore
  id/Uuid

  cli_/Cli
  devices_/List := ?
  group-pods_/Map
  aliases_/Map := {:}

  constructor .store --cli/Cli:
    id = store.id
    cli_ = cli
    devices_ = store.devices
    group-pods_ = store.group-pods
    aliases_ = build-alias-map_ devices_ --cli=cli

  /** Returns the declared groups and their desired pod references. */
  groups -> Map:
    return group-pods_

  /** Returns the complete declared device inventory. */
  devices -> List:
    return devices_

  /** Returns the desired pod reference for $name. */
  pod-reference-for-group name/string -> PodReference:
    return group-pods_.get name
        --if-absent=: cli_.ui.abort "Unknown group '$name'"

  /** Returns whether the fleet contains $group. */
  has-group group/string -> bool:
    return group-pods_.contains group

  /** Adds a group. */
  add-group name/string pod-reference/PodReference -> none:
    if has-group name:
      cli_.ui.abort "Group '$name' already exists."
    group-pods_[name] = pod-reference
    store.save-fleet --group-pods=group-pods_

  /** Updates a group's desired pod reference. */
  update-group name/string pod-reference/PodReference -> none:
    if not has-group name:
      cli_.ui.abort "Group '$name' does not exist."
    group-pods_[name] = pod-reference
    store.save-fleet --group-pods=group-pods_

  /** Renames a group and moves its devices to the new name. */
  rename-group from/string to/string -> none:
    if not has-group from:
      cli_.ui.abort "Group '$from' does not exist."
    if has-group to:
      cli_.ui.abort "Group '$to' already exists."

    pod-reference := group-pods_[from]
    group-pods_.remove from
    group-pods_[to] = pod-reference
    devices_ = devices_.map: | device/DeviceFleet |
      device.group == from ? device.with --group=to : device
    save-devices_
    store.save-fleet --group-pods=group-pods_

  /** Removes an unused group. */
  remove-group group/string -> bool:
    if not has-group group: return false
    if (devices_.any: it.group == group):
      cli_.ui.abort "Group '$group' is in use."
    group-pods_.remove group
    store.save-fleet --group-pods=group-pods_
    return true

  /** Moves selected devices to a group and returns the number moved. */
  move-devices -> int
      --ids/Set
      --groups/Set
      --to/string:
    if not has-group to:
      cli_.ui.abort "Group '$to' does not exist."

    moved-count := 0
    devices_ = devices_.map: | device/DeviceFleet |
      if ids.contains device.id or groups.contains device.group:
        moved-count++
        device.with --group=to
      else:
        device
    if moved-count != 0: save-devices_
    return moved-count

  /** Adds a declared device. */
  add-device --device-id/Uuid --name/string? --group/string --aliases/List?:
    if aliases and aliases.is-empty: aliases = null
    devices_.add
        DeviceFleet
            --id=device-id
            --group=group
            --name=name
            --aliases=aliases
    save-devices_
    aliases_ = build-alias-map_ devices_ --cli=cli_

  /** Resolves a device ID, name, or alias. */
  resolve-alias alias/string -> DeviceFleet:
    if not aliases_.contains alias:
      cli_.ui.abort "No device with name, device-id, or alias '$alias' in the fleet."
    index := aliases_[alias]
    if index == AMBIGUOUS_:
      cli_.ui.abort "The name, device-id, or alias '$alias' is ambiguous."
    return devices_[index]

  /** Returns the declared device with $device-id. */
  device device-id/Uuid -> DeviceFleet:
    devices_.do: | fleet-device/DeviceFleet |
      if fleet-device.id == device-id: return fleet-device
    cli_.ui.abort "No device with id $device-id in the fleet."
    unreachable

  save-devices_ -> none:
    store.save-devices devices_

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
Provides the legacy combined fleet, broker, pod, and artifact command surface.

Workspace-backed orchestration replaces this compatibility façade. New fleet
  state operations should use $Fleet.
*/
class LegacyFleet:
  id/Uuid
  broker-scope/Scope
  artemis/Artemis
  broker/Broker
  migrating-brokers_/Map
  wiring/LegacyFleetWiring
  declared-fleet_/Fleet?

  cli_/Cli

  /** Constructs the compatibility façade from already-opened dependencies. */
  constructor .wiring .artemis .broker
      --fleet/Fleet?=null
      --migrating-brokers/Map
      --cli/Cli
      --validate-organization/bool=true:
    id = wiring.id
    broker-config/ServerConfig := wiring.servers[wiring.broker-name]
    broker-scope = broker-config.scope
    cli_ = cli
    migrating-brokers_ = migrating-brokers
    declared-fleet_ = fleet

    if validate-organization:
      // TODO(florian): should we always do this check?
      org := artemis.get-organization --id=organization-id
      if not org:
        cli.ui.abort "Organization $organization-id does not exist or is not accessible."

  fleet_ -> Fleet:
    if not declared-fleet_:
      cli_.ui.abort "This operation requires complete declared fleet state."
    return declared-fleet_

  /**
  The organization-id encoded inside $broker-scope.

  Kept as a derived view for callers that talk to the auth provider
    (which is still org-id concrete).
  */
  organization-id -> Uuid:
    return Uuid.parse broker-scope.to-json

  write-reference --path/string -> none:
    wiring.write-reference --path=path

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
    return wiring.recovery-urls

  recovery-url-add url/string -> none:
    old-urls := wiring.recovery-urls
    if old-urls.contains url:
      cli_.ui.emit --info "Recovery URL '$url' already exists."
      return
    new-urls := old-urls + [url]
    wiring.save-wiring --recovery-urls=new-urls

  recovery-url-remove url/string -> bool:
    old-urls := wiring.recovery-urls
    new-urls := old-urls.filter: it != url
    if old-urls.size == new-urls.size:
      return false

    wiring.save-wiring --recovery-urls=new-urls
    return true

  recovery-urls-remove-all -> none:
    wiring.save-wiring --recovery-urls=[]

  recovery-info -> ByteArray:
    json-config := broker.server-config.to-service-json
        --base64
        --der-serializer=: unreachable
    return json.encode json-config

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

    new-file := "$output-directory/$(id).identity"

    provision --device-id=id --out-path=new-file

    fleet_.add-device
        --device-id=id
        --group=group
        --aliases=aliases
        --name=name

    return new-file

  /**
  Returns the pod for the given $device.
  */
  pod-for device/DeviceFleet -> Pod:
    return download (pod-reference-for-group device.group)

  update --device-id/Uuid --pod/Pod:
    broker.update --device-id=device-id --pod=pod

    // We need to notify the migrating-from brokers.
    wiring.migrating-from.do: | server-name |
      cli_.ui.emit --info "Updating on '$server-name' broker (migration in progress)."
      old-broker/Broker := migrating-brokers_[server-name]
      old-broker.update --device-id=device-id --pod=pod

  /**
  Rolls out the local configuration to the broker.

  The $diff-bases is a list of pods to build patches against if
    a device hasn't set its state yet.
  */
  roll-out --diff-bases/List:
    ui := cli_.ui

    fleet-devices := fleet_.devices
    device-ids := fleet-devices.map: it.id

    detailed-devices := broker.get-devices --device-ids=device-ids
    fleet-devices.do: | fleet-device/DeviceFleet |
      if not detailed-devices.contains fleet-device.id:
        ui.abort "Device $fleet-device.id is unknown to the broker."

    pods-per-group := {:}  // From group-name to Pod.
    pods := fleet-devices.map: | fleet-device/DeviceFleet |
      group-name := fleet-device.group
      pods-per-group.get group-name --init=: download (pod-reference-for-group group-name)

    is-migrating := not wiring.migrating-from.is-empty
    broker.roll-out
        --devices=detailed-devices.values
        --pods=pods
        --diff-bases=diff-bases
        --warn-only-trivial=not is-migrating

    ui.emit --info "Successfully updated $(fleet-devices.size) device$(fleet-devices.size == 1 ? "" : "s")."

    // We need to notify the migrating-from brokers.
    wiring.migrating-from.do: | server-name |
      ui.emit --info "Rolling out to '$server-name' broker (migration in progress)."
      old-broker/Broker := migrating-brokers_[server-name]
      // We could filter out devices that were already known in the new broker, but
      // it's easier and more robust to update all devices.
      // This also makes it possible to move forward and backward between two brokers.
      detailed-devices = old-broker.get-devices --device-ids=device-ids
      old-broker.roll-out --devices=detailed-devices.values --pods=pods --diff-bases=diff-bases
      ui.emit --info "Successfully rolled out to '$server-name' broker (migration in progress)."

  pod-reference-for-group name/string -> PodReference:
    return fleet_.pod-reference-for-group name

  /** Returns the declared groups and their desired pod references. */
  groups -> Map:
    return fleet_.groups

  /** Returns the declared device inventory. */
  devices -> List:
    return fleet_.devices

  has-group group/string -> bool:
    return fleet_.has-group group

  add-group name/string pod-reference/PodReference -> none:
    fleet_.add-group name pod-reference

  update-group name/string pod-reference/PodReference -> none:
    fleet_.update-group name pod-reference

  rename-group from/string to/string -> none:
    fleet_.rename-group from to

  remove-group group/string -> bool:
    return fleet_.remove-group group

  move-devices -> int
      --ids/Set
      --groups/Set
      --to/string:
    return fleet_.move-devices --ids=ids --groups=groups --to=to

  add-device --device-id/Uuid --name/string? --group/string --aliases/List?:
    fleet_.add-device
        --device-id=device-id
        --name=name
        --group=group
        --aliases=aliases

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
    max-offline := max-offline-s and max-offline-s > 0
        ? Duration --s=max-offline-s
        : DEFAULT-MAX-OFFLINE

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
    migrating-from-brokers := wiring.migrating-from.map: | name/string |
      migrating-brokers_[name]

    all-brokers := [broker] + migrating-from-brokers

    device-ids := fleet_.devices.map: it.id
    id-to-fleet-device := {:}
    fleet_.devices.do: | device/DeviceFleet |
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
    return fleet_.resolve-alias alias

  device device-id/Uuid ->  DeviceFleet:
    return fleet_.device device-id

  /**
  Provisions a device.

  Registers the device with the broker. If the same server also provides the
    Artemis device registry, provisioning creates the corresponding registry
    row as well.

  Writes the identity file to $out-path.
  */
  provision --device-id/Uuid --out-path/string:
    // Ensure that we are authenticated with both the auth provider and
    // the broker before doing anything visible. The auth-provider check
    // gates access; the broker is what actually receives the new device.
    artemis.ensure-authenticated
    broker.ensure-authenticated

    device := Device
        --id=device-id
        --organization-id=organization-id

    broker.notify-created device

    write-identity-file device --out-path=out-path

  /**
  Writes an identity file.

  This file is used to build a device image and needs to be given to
    $Pod.compute-device-specific-data.
  */
  write-identity-file --out-path/string device/Device -> none:
    write-base64-ubjson-to-file out-path device.to-json-identity

  migration-start new-broker/Broker:
    new-broker-config := new-broker.server-config

    if new-broker.server-config.name == broker.server-config.name:
      // Do nothing. We are already running on this broker.
      return

    detailed-devices := broker.get-devices --device-ids=(fleet_.devices.map: it.id)
    new-devices := new-broker.get-devices --device-ids=(fleet_.devices.map: it.id)

    detailed-devices.do --values: | device/Device |
      // Only notify the new broker about devices that are not known to it.
      if not new-devices.contains device.id:
        new-broker.notify-created device

    old-servers := wiring.servers
    new-servers := old-servers
    if not old-servers.contains new-broker-config.name:
      new-servers = old-servers.copy
      new-servers[new-broker-config.name] = new-broker-config

    old-migrating-from := wiring.migrating-from
    new-migrating-from := old-migrating-from
    if old-migrating-from.is-empty:
      new-migrating-from = [broker.server-config.name]
    else if not old-migrating-from.contains broker.server-config.name:
      new-migrating-from = old-migrating-from.copy
      new-migrating-from.add broker.server-config.name

    new-migrating-from.filter --in-place: | name/string |
      name != new-broker-config.name

    wiring.save-wiring
        --broker-name=new-broker-config.name
        --migrating-from=new-migrating-from
        --servers=new-servers

  migration-stop broker-names/List --force/bool:
    migrating-from := wiring.migrating-from

    if broker-names.is-empty: broker-names = migrating-from

    if not force:
      // Check that all devices have migrated.
      device-ids := fleet_.devices.map: it.id
      detailed-devices := broker.get-devices --device-ids=device-ids
      last-events := broker.get-last-events --device-ids=device-ids

      broker-names.do: | name/string |
        current-broker/Broker := migrating-brokers_[name]
        current-detailed-devices := current-broker.get-devices --device-ids=device-ids
        current-ids := current-detailed-devices.keys
        current-last-events := current-broker.get-last-events --device-ids=current-ids
        current-last-events.do: | device-id/Uuid event/Event |
          if not last-events.contains device-id or last-events[device-id].timestamp < event.timestamp:
            fleet_.devices.do: | fleet-device/DeviceFleet |
              if fleet-device.id == device-id:
                cli_.ui.abort "Device $fleet-device.short-string has not migrated yet."
            unreachable

    brokers-set := Set
    new-migrating-from := ?
    brokers-set.add-all broker-names
    new-migrating-from = migrating-from.filter: not brokers-set.contains it

    main-broker := wiring.broker-name
    new-servers := wiring.servers.filter: | name/string _ |
      name == main-broker or not brokers-set.contains name

    wiring.save-wiring
        --migrating-from=new-migrating-from
        --servers=new-servers

  static device-from --identity-path/string -> Device:
    identity := read-base64-ubjson identity-path
    device-map := identity["artemis.device"]
    return Device
        --id=Uuid.parse device-map["device_id"]
        --organization-id=Uuid.parse device-map["organization_id"]
