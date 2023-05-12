// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import encoding.ubjson
import host.file
import uuid

import .artemis
import .cache
import .device
import .event
import .firmware
import .pod
import .pod_specification
import .pod_registry
import .ui
import .utils
import .utils.names
import ..shared.json_diff

class DeviceFleet:
  id/uuid.Uuid

  name/string?
  aliases/List?

  constructor --.id --.name=(random_name --uuid=id) --.aliases=null:

  constructor.from_json encoded_id/string encoded/Map:
    id = uuid.parse encoded_id
    name = encoded.get "name"
    aliases = encoded.get "aliases"

  short_string -> string:
    if name: return "$id ($name)"
    return "$id"

class Status_:
  static CHECKIN_VERIFICATION_COUNT ::= 5
  static UNKNOWN_MISSED_CHECKINS ::= -1
  never_seen/bool
  last_seen/Time?
  is_fully_updated/bool
  /** Number of missed checkins out of $CHECKIN_VERIFICATION_COUNT. */
  missed_checkins/int
  is_modified/bool

  constructor --.never_seen --.is_fully_updated --.missed_checkins --.last_seen --.is_modified:

  is_healthy -> bool:
    return is_fully_updated and missed_checkins == 0

class Fleet:
  static DEVICES_FILE_ ::= "devices.json"
  static FLEET_FILE_ ::= "fleet.json"
  static DEFAULT_SPECIFICATION_ ::= "specification.json"
  /** Signal that an alias is ambiguous. */
  static AMBIGUOUS_ ::= -1

  id/uuid.Uuid
  artemis_/Artemis
  ui_/Ui
  cache_/Cache
  fleet_root_/string
  devices_/List
  organization_id/uuid.Uuid
  default_specification_/string
  /** Map from name, device-id, alias to index in $devices_. */
  aliases_/Map := {:}

  constructor .fleet_root_ .artemis_ --ui/Ui --cache/Cache:
    ui_ = ui
    cache_ = cache
    if not file.is_file "$fleet_root_/$FLEET_FILE_":
      ui_.error "Fleet root $fleet_root_ does not contain a $FLEET_FILE_ file."
      ui_.error "Use 'init' to initialize a fleet root."
      ui_.abort
    fleet_content := read_json "$fleet_root_/$FLEET_FILE_"
    if fleet_content is not Map:
      ui_.abort "Fleet file $fleet_root_/$FLEET_FILE_ has invalid format."
    organization_id = uuid.parse fleet_content["organization"]
    default_specification_ = fleet_content["default-specification"]
    if not fleet_content.contains "id":
      ui.error "Fleet file $fleet_root_/$FLEET_FILE_ does not contain an ID."
      ui.error "Please add an entry with a random UUID to it."
      ui.error "You can use the following line:"
      ui.error "  \"id\": \"$random_uuid\","
      ui.abort
    id = uuid.parse fleet_content["id"]
    devices_ = load_devices_ fleet_root_ --ui=ui
    aliases_ = build_alias_map_ devices_ ui

    // TODO(florian): should we always do this check?
    org := artemis_.connected_artemis_server.get_organization organization_id
    if not org:
      ui.abort "Organization $organization_id does not exist or is not accessible."

  static init fleet_root/string artemis/Artemis --organization_id/uuid.Uuid --ui/Ui:
    if not file.is_directory fleet_root:
      ui.abort "Fleet root $fleet_root is not a directory."

    if file.is_file "$fleet_root/$FLEET_FILE_":
      ui.abort "Fleet root $fleet_root already contains a $FLEET_FILE_ file."

    if file.is_file "$fleet_root/$DEVICES_FILE_":
      ui.abort "Fleet root $fleet_root already contains a $DEVICES_FILE_ file."

    org := artemis.connected_artemis_server.get_organization organization_id
    if not org:
      ui.abort "Organization $organization_id does not exist or is not accessible."

    write_json_to_file --pretty "$fleet_root/$FLEET_FILE_" {
      "id": "$random_uuid",
      "organization": "$organization_id",
      "default-specification": DEFAULT_SPECIFICATION_,
    }
    write_json_to_file --pretty "$fleet_root/$DEVICES_FILE_" {:}

    default_specification_path := "$fleet_root/$DEFAULT_SPECIFICATION_"
    if not file.is_file default_specification_path:
      write_json_to_file --pretty default_specification_path INITIAL_POD_SPECIFICATION

    ui.info "Fleet root $fleet_root initialized."

  static load_devices_ fleet_root/string --ui/Ui -> List:
    if not file.is_directory fleet_root:
      ui.abort "Fleet root $fleet_root is not a directory."
    devices_path := "$fleet_root/$DEVICES_FILE_"
    if not file.is_file devices_path:
      ui.error "Fleet root $fleet_root does not contain a $DEVICES_FILE_ file."
      ui.error "Use 'init' to initialize a fleet root."
      ui.abort

    encoded_devices := null
    exception := catch: encoded_devices = read_json devices_path
    if exception:
      ui.error "Fleet file $devices_path is not a valid JSON."
      ui.error exception.message
      ui.abort
    if encoded_devices is not Map:
      ui.abort "Fleet file $devices_path has invalid format."

    devices := []
    encoded_devices.do: | device_id encoded_device |
      if encoded_device is not Map:
        ui.abort "Fleet file $devices_path has invalid format for device ID $device_id."
      exception = catch:
        device := DeviceFleet.from_json device_id encoded_device
        devices.add device
      if exception:
        ui.error "Fleet file $devices_path has invalid format for device ID $device_id."
        ui.error exception.message
        ui.abort
    return devices

  /**
  Builds an alias map.

  When referring to devices we allow names, device-ids and aliases as
    designators. This function builds a map for these and warns the
    user if any of them is ambiguous.
  */
  static build_alias_map_ devices/List ui/Ui -> Map:
    result := {:}
    ambiguous_ids := {:}
    devices.size.repeat: | i/int |
      device/DeviceFleet := devices[i]
      add_alias := : | id/string |
        if result.contains id:
          old := result[id]
          if old == i:
            // The name, device-id or alias appears twice for the same
            // device. Not best practice, but not ambiguous.
            continue.add_alias

          if old == AMBIGUOUS_:
            ambiguous_ids[id].add id
          else:
            ambiguous_ids[id] = [old, id]
            result[id] = AMBIGUOUS_
        else:
          result[id] = i

      add_alias.call "$device.id"
      if device.name:
        add_alias.call device.name
      if device.aliases:
        device.aliases.do: | alias/string |
          add_alias.call alias
    if ambiguous_ids.size > 0:
      ui.warning "The following names, device-ids or aliases are ambiguous:"
      ambiguous_ids.do: | id index_list/List |
        uuid_list := index_list.map: devices[it].id
        ui.warning "  $id maps to $(uuid_list.join ", ")"
    return result

  write_devices_ -> none:
    encoded_devices := {:}
    devices_.do: | device/DeviceFleet |
      entry := {:}
      if device.name: entry["name"] = device.name
      if device.aliases: entry["aliases"] = device.aliases
      encoded_devices["$device.id"] = entry
    write_json_to_file --pretty "$fleet_root_/$DEVICES_FILE_" encoded_devices

  /**
  Returns a list of created files.
  */
  create_identities --output_directory/string count/int -> List:
    old_size := devices_.size
    try:
      new_identity_files := []
      count.repeat: | i/int |
        device_id := random_uuid

        output := "$output_directory/$(device_id).identity"

        artemis_.provision
            --device_id=device_id
            --out_path=output
            --organization_id=organization_id

        devices_.add (DeviceFleet --id=device_id)
        new_identity_files.add output
      return new_identity_files
    finally:
      if devices_.size != old_size:
        write_devices_

  update --diff_bases/List:
    broker := artemis_.connected_broker
    detailed_devices := {:}
    fleet_devices := devices_
    specification_path := "$fleet_root_/$DEFAULT_SPECIFICATION_"

    existing_devices := broker.get_devices --device_ids=(fleet_devices.map: it.id)
    fleet_devices.do: | fleet_device/DeviceFleet |
      if not existing_devices.contains fleet_device.id:
        ui_.abort "Device $fleet_device.id is unknown to the broker."

    base_patches := {:}

    base_firmwares := diff_bases.map: | diff_base/string |
      pod := Pod.parse diff_base --tmp_directory=artemis_.tmp_directory --ui=ui_
      FirmwareContent.from_envelope pod.envelope_path --cache=cache_

    base_firmwares.do: | content/FirmwareContent |
      trivial_patches := artemis_.extract_trivial_patches content
      trivial_patches.do: | _ patch/FirmwarePatch |
        artemis_.upload_patch patch --organization_id=organization_id

    pod := Pod.from_specification
        --path=specification_path
        --artemis=artemis_
        --ui=ui_

    fleet_devices.do: | fleet_device/DeviceFleet |
      artemis_.update
          --device_id=fleet_device.id
          --pod=pod
          --base_firmwares=base_firmwares

      ui_.info "Successfully updated device $fleet_device.short_string."

  /**
  Uploads the given $pod to the broker.

  Also uploads the trivial patches.
  */
  upload --pod/Pod --tags/List -> none:
    artemis_.upload --pod=pod --organization_id=organization_id

    broker := artemis_.connected_broker
    pod.split: | manifest/Map parts/Map |
      parts.do: | id/string content/ByteArray |
        // Only upload if we don't have it in our cache.
        key := "$POD_PARTS_PATH/$organization_id/$id"
        cache_.get_file_path key: | store/FileStore |
          broker.pod_registry_upload_pod_part content --part_id=id
              --organization_id=organization_id
          store.save content
      key := "$POD_MANIFEST_PATH/$organization_id/$pod.id"
      cache_.get_file_path key: | store/FileStore |
        encoded := ubjson.encode manifest
        broker.pod_registry_upload_pod_manifest encoded --pod_id=pod.id
            --organization_id=organization_id
        store.save encoded

    description_ids := broker.pod_registry_descriptions
        --fleet_id=this.id
        --organization_id=this.organization_id
        --names=[pod.name]
        --create_if_absent

    description_id := (description_ids[0] as PodRegistryDescription).id

    broker.pod_registry_add
        --pod_description_id=description_id
        --pod_id=pod.id

    tags.do:
      broker.pod_registry_tag_set
          --pod_description_id=description_id
          --pod_id=pod.id
          --tag=it

    ui_.info "Successfully uploaded pod to organization $organization_id."

  list_pods --names/List -> Map:
    broker := artemis_.connected_broker
    descriptions := ?
    if names.is_empty:
      descriptions = broker.pod_registry_descriptions --fleet_id=this.id
    else:
      descriptions = broker.pod_registry_descriptions
          --fleet_id=this.id
          --organization_id=this.organization_id
          --names=names
          --no-create_if_absent
    result := {:}
    descriptions.do: | description/PodRegistryDescription |
      pods := broker.pod_registry_pods --pod_description_id=description.id
      result[description] = pods
    return result

  default_specification_path -> string:
    return "$fleet_root_/$default_specification_"

  read_specification_for device_id/uuid.Uuid -> PodSpecification:
    return parse_pod_specification_file default_specification_path --ui=ui_

  add_device --device_id/uuid.Uuid --name/string? --aliases/List?:
    if aliases and aliases.is_empty: aliases = null
    devices_.add (DeviceFleet --id=device_id --name=name --aliases=aliases)
    write_devices_

  build_status_ device/DeviceDetailed get_state_events/List? last_event/Event? -> Status_:
    CHECKIN_VERIFICATIONS ::= 5
    SLACK_FACTOR ::= 0.3
    firmware_state := device.reported_state_firmware
    current_state := device.reported_state_current
    if not firmware_state:
      if not last_event:
        return Status_
            --is_fully_updated=false
            --missed_checkins=Status_.UNKNOWN_MISSED_CHECKINS
            --never_seen=true
            --last_seen=null
            --is_modified=false

      return Status_
          --is_fully_updated=false
          --missed_checkins=Status_.UNKNOWN_MISSED_CHECKINS
          --never_seen=false
          --last_seen=last_event.timestamp
          --is_modified=false

    goal := device.goal
    is_updated/bool := ?
    // TODO(florian): remove the special case of `null` meaning "back to firmware".
    if not goal and not current_state:
      is_updated = true
    else if not goal:
      is_updated = false
    else:
      is_updated = json_equals firmware_state goal
    max_offline_s/int? := firmware_state.get "max-offline"
    // If the device has no max_offline, we assume it's 20 seconds.
    // TODO(florian): handle this better.
    if not max_offline_s:
      max_offline_s = 20
    max_offline := Duration --s=max_offline_s

    missed_checkins/int := ?
    if not get_state_events or get_state_events.is_empty:
      missed_checkins = Status_.UNKNOWN_MISSED_CHECKINS
    else:
      slack := max_offline * SLACK_FACTOR
      missed_checkins = 0
      checkin_index := CHECKIN_VERIFICATIONS - 1
      last := Time.now
      earliest_time := last - (max_offline * CHECKIN_VERIFICATIONS)
      for i := 0; i < get_state_events.size; i++:
        event := get_state_events[i]
        event_timestamp := event.timestamp
        if event_timestamp < earliest_time:
          event_timestamp = earliest_time
          // We want to handle this interval, but no need to look at more
          // events.
          i = get_state_events.size
        duration_since_last_checkin := event_timestamp.to last
        missed := (duration_since_last_checkin - slack).in_ms / max_offline.in_ms
        missed_checkins += missed
        last = event.timestamp
    return Status_
        --is_fully_updated=is_updated
        --missed_checkins=missed_checkins
        --never_seen=false
        --last_seen=last_event and last_event.timestamp
        --is_modified=device.reported_state_current != null

  status --include_healthy/bool --include_never_seen/bool:
    broker := artemis_.connected_broker
    device_ids := devices_.map: it.id
    detailed_devices := broker.get_devices --device_ids=device_ids
    get_state_events := broker.get_events
        --device_ids=device_ids
        --limit=Status_.CHECKIN_VERIFICATION_COUNT
        --types=["get-goal"]
    last_events := broker.get_events --device_ids=device_ids --limit=1

    pod_ids := []
    devices_.do: | fleet_device/DeviceFleet |
      device/DeviceDetailed? := detailed_devices.get fleet_device.id
      if not device:
        ui_.abort "Device $fleet_device.id is unknown to the broker."
      pod_id := device.pod_id_current or device.pod_id_firmware
      // Add nulls as well.
      pod_ids.add pod_id

    pod_id_entries := broker.pod_registry_pods
        --fleet_id=this.id
        --pod_ids=(pod_ids.filter: it != null)
    pod_entry_map := {:}
    pod_id_entries.do: | entry/PodRegistryEntry |
      pod_entry_map[entry.id] = entry
    description_set := {}
    description_set.add_all
        (pod_id_entries.map: | entry/PodRegistryEntry | entry.pod_description_id)
    description_ids := []
    description_ids.add_all description_set
    descriptions := broker.pod_registry_descriptions --ids=description_ids
    description_map := {:}
    descriptions.do: | description/PodRegistryDescription |
      description_map[description.id] = description

    now := Time.now
    statuses := devices_.map: | fleet_device/DeviceFleet |
      device/DeviceDetailed? := detailed_devices.get fleet_device.id
      if not device:
        ui_.abort "Device $fleet_device.id is unknown to the broker."
      last_events_of_device := last_events.get fleet_device.id
      last_event := last_events_of_device and not last_events_of_device.is_empty
          ? last_events_of_device[0]
          : null
      build_status_ device (get_state_events.get fleet_device.id) last_event

    rows := []
    for i := 0; i < devices_.size; i++:
      fleet_device/DeviceFleet := devices_[i]
      pod_id/uuid.Uuid? := pod_ids[i]
      status/Status_ := statuses[i]
      if not include_healthy and status.is_healthy: continue
      if not include_never_seen and status.never_seen: continue

      pod_name := ""
      if pod_id:
        entry/PodRegistryEntry? := pod_entry_map.get pod_id
        if not entry:
          pod_name = "$pod_id"
        else:
          description/PodRegistryDescription := description_map.get entry.pod_description_id
          pod_name = "$description.name#$entry.revision"
          if not entry.tags.is_empty:
            pod_name += " $(entry.tags.join ",")"

      cross := "✗"
      // TODO(florian): when the UI wants structured output we shouldn't change the last
      // seen to human readable.
      human_last_seen := ""
      if status.last_seen:
        human_last_seen = timestamp_to_human_readable status.last_seen
      else if status.never_seen:
        human_last_seen = "never"
      else:
        human_last_seen = "unknown"
      missed_checkins_string := ""
      if status.missed_checkins == Status_.UNKNOWN_MISSED_CHECKINS:
        missed_checkins_string = "?"
      else if status.missed_checkins > 0:
        missed_checkins_string = cross
      rows.add [
        "$fleet_device.id",
        fleet_device.name or "",
        pod_name,
        status.is_fully_updated ? "" : cross,
        status.is_modified ? cross : "",
        missed_checkins_string,
        human_last_seen,
        fleet_device.aliases ? fleet_device.aliases.join ", " : "",
      ]

    ui_.info_table rows
        --header=["Device ID", "Name", "Pod", "Outdated", "Modified", "Missed Checkins", "Last Seen", "Aliases"]

  resolve_alias_ alias/string -> DeviceFleet:
    if not aliases_.contains alias:
      ui_.abort "No device with name, device-id, or alias $alias in the fleet."
    device_index := aliases_[alias]
    if device_index == AMBIGUOUS_:
      ui_.abort "The name, device-id, or alias $alias is ambiguous."
    return devices_[device_index]
