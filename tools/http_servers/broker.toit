// Copyright (C) 2022 Toitware ApS. All rights reserved.

import artemis.shared.constants show *
import cli
import encoding.json
import monitor

import .base

main args:
  root_cmd := cli.Command "root"
    --long_help="""An HTTP-based broker.

      Can be used to let devices and the CLI communicate with each other.
      This server keeps data in memory and should thus only be used for
      testing.
      """
    --options=[
      cli.OptionInt "port" --short_name="p"
          --short_help="The port to listen on."
    ]
    --run=:: | parsed/cli.Parsed |
      broker := HttpBroker parsed["port"]
      broker.start

  root_cmd.run args

class PodDescription:
  id/int
  name/string
  description/string? := ?
  fleet_id/string
  pods/Map  // Map from pod-id to list of tags.
  pod_revisions/Map // Map from pod-id to revision.
  pod_created_ats/Map // Map from pod-id to created-at timestamp.
  revision_counter/int := 0

  constructor --.id --.fleet_id --.name --.description:
    pods = {:}
    pod_revisions = {:}
    pod_created_ats = {:}

class HttpBroker extends HttpServer:
  storage_/Map := {:}
  device_states_/Map := {:}
  device_goals_/Map := {:}
  events_/Map := {:}  // Map from device-id to list of events.

  /* Pod description related fields. */
  pod_description_ids_ := 0
  pod_registry_/Map ::= {:}  // Map from pod-description ID to $PodDescription object.

  constructor port/int:
    super port

  run_command command/int encoded/ByteArray _ -> any:
    data := ?
    if command == COMMAND_UPLOAD_:
      path_end := encoded.index_of '\0'
      path := encoded[0..path_end].to_string
      content := encoded[path_end + 1 ..]
      data = {
        "path": path,
        "content": content,
      }
    else:
      data = json.decode encoded


    if command == COMMAND_UPLOAD_: return upload data
    if command == COMMAND_DOWNLOAD_: return download data
    if command == COMMAND_UPDATE_GOAL_: return update_goal data
    if command == COMMAND_GET_DEVICES_: return get_devices data
    if command == COMMAND_NOTIFY_BROKER_CREATED_: return notify_created data
    if command == COMMAND_GET_EVENTS_: return get_events data
    if command == COMMAND_GET_GOAL_: return get_goal data
    if command == COMMAND_GET_GOAL_NO_EVENT_: return get_goal_no_event data
    if command == COMMAND_REPORT_STATE_: return report_state data
    if command == COMMAND_GET_STATE_: return get_state data
    if command == COMMAND_REPORT_EVENT_: return report_event data

    if command == COMMAND_POD_REGISTRY_DESCRIPTION_UPSERT_:
      return pod_registry_description_upsert data
    if command == COMMAND_POD_REGISTRY_ADD_:
      return pod_registry_add data
    if command == COMMAND_POD_REGISTRY_TAG_SET_:
      return pod_registry_tag_set data
    if command == COMMAND_POD_REGISTRY_TAG_REMOVE_:
      return pod_registry_tag_remove data
    if command == COMMAND_POD_REGISTRY_DESCRIPTIONS_:
      return pod_registry_descriptions data
    if command == COMMAND_POD_REGISTRY_DESCRIPTIONS_BY_IDS_:
      return pod_registry_descriptions_by_ids data
    if command == COMMAND_POD_REGISTRY_DESCRIPTIONS_BY_NAMES_:
      return pod_registry_descriptions_by_names data
    if command == COMMAND_POD_REGISTRY_PODS_:
      return pod_registry_pods data
    if command == COMMAND_POD_REGISTRY_PODS_BY_IDS_:
      return pod_registry_pods_by_ids data
    if command == COMMAND_POD_REGISTRY_POD_IDS_BY_REFERENCE_:
      return pod_registry_pod_ids_by_reference data

    print "Unknown command: $command"
    throw "BAD COMMAND $command"

  notify_created data/Map:
    device_id := data["_device_id"]
    state := data["_state"]
    device_states_[device_id] = state

  /** Backdoor for creating a new device. */
  create_device --device_id/string --state/Map:
    device_states_[device_id] = state

  get_goal data/Map -> Map?:
    device_id := data["_device_id"]
    // Automatically adds an event.
    result := get_goal_no_event data
    report_event device_id "get-goal" null
    return result

  get_goal_no_event data/Map -> Map?:
    device_id := data["_device_id"]
    return device_goals_.get device_id

  update_goal data/Map:
    device_id := data["_device_id"]
    device_goals_[device_id] = data["_goal"]
    print "Updating goal state for $device_id to $device_goals_[device_id]."

  upload data/Map:
    path := data["path"]
    storage_[path] = data["content"]

  download data/Map:
    path := data["path"]
    bytes := storage_[path]
    offset := (data.get "offset") or 0
    size := data.get "size"
    part_end := ?
    if size:
      part_end = min bytes.size (offset + size)
    else:
      part_end = bytes.size
    if offset != 0 or part_end != bytes.size:
      return BinaryResponse bytes[offset..part_end] bytes.size
    return BinaryResponse bytes bytes.size

  report_state data/Map:
    device_id := data["_device_id"]
    device_states_[device_id] = data["_state"]
    // Automatically adds an event.
    report_event device_id "update-state" data["_state"]

  get_state data/Map:
    device_id := data["_device_id"]
    return get_state --device_id=device_id

  get_state --device_id/string -> Map?:
    return device_states_.get device_id

  remove_device device_id/string:
    device_states_.remove device_id
    device_goals_.remove device_id

  report_event data/Map:
    device_id := data["_device_id"]
    event_type := data["_type"]
    payload := data["_data"]
    report_event device_id event_type payload

  report_event device_id/string event_type/string payload/any:
    print "report-event: $device_id $event_type $payload"
    event_list := events_.get device_id --init=:[]
    event_list.add {
      "event_type": event_type,
      "data": payload,
      "timestamp": Time.now,
    }

  get_events data/Map:
    types := data["_types"]
    device_ids := data["_device_ids"]
    limit := data.get "_limit"
    since := data.get "_since"
    since_time := since and Time.from_string since

    type_set := {}
    if types: type_set.add_all types

    result := []
    device_ids.do: | device_id |
      if not device_states_.contains device_id:
        throw "Unknown device: $device_id"
      events := events_.get device_id --if_absent=:[]
      count := 0
      // Iterate backwards to get the most recent events first.
      for i := events.size - 1; i >= 0; i--:
        event := events[i]
        if types and not type_set.contains event["event_type"]: continue
        if since_time and event["timestamp"] <= since_time: continue
        result.add {
          "device_id": device_id,
          "type": event["event_type"],
          "ts": "$((event["timestamp"] as Time).utc.to_iso8601_string)",
          "data": event["data"],
        }
        count++
        if limit and count >= limit: break
    return result

  get_devices data/Map:
    device_ids := data["_device_ids"]
    result := []
    device_ids.do: | device_id |
      state := device_states_.get device_id
      goal := device_goals_.get device_id
      if not goal and not state: continue.do
      result.add {
        "device_id": device_id,
        "state": state,
        "goal": goal,
      }
    return result

  clear_events:
    events_.clear

  pod_registry_description_upsert data/Map:
    fleet_id := data["_fleet_id"]
    organization_id := data["_organization_id"]
    name := data["_name"]
    description := data.get "_description"

    pod_registry_.do: | id pod_description/PodDescription |
      if pod_description.fleet_id == fleet_id and
          pod_description.name == name:
        pod_description.description = description
        return id

    id := pod_description_ids_++
    pod_description := PodDescription
        --id=id
        --name=name
        --description=description
        --fleet_id=fleet_id
    pod_registry_[id] = pod_description
    return id

  pod_registry_add data/Map:
    pod_description_id := data["_pod_description_id"]
    pod_id := data["_pod_id"]
    description/PodDescription := pod_registry_[pod_description_id]
    revision := description.revision_counter + 1
    created_at := Time.now.utc.to_iso8601_string
    description.revision_counter++
    description.pods[pod_id] = []
    description.pod_revisions[pod_id] = revision
    description.pod_created_ats[pod_id] = created_at

  pod_registry_tag_set data/Map:
    pod_description_id := data["_pod_description_id"]
    pod_id := data["_pod_id"]
    tag := data["_tag"]
    force := data["_force"]

    description/PodDescription := pod_registry_[pod_description_id]
    description.pods.do: | _ tags |
      if force:
        tags.remove tag
      else if tags.contains tag:
        throw "Tag already exists: $tag"
    description.pods[pod_id].add tag

  pod_registry_tag_remove data/Map:
    pod_description_id := data["_pod_description_id"]
    tag := data["_tag"]

    description/PodDescription := pod_registry_[pod_description_id]
    description.pods.do: | _ tags/List |
      if tags.contains tag:
        tags.remove tag
        return

  pod_registry_descriptions data/Map:
    fleet_id := data["_fleet_id"]

    result := []
    pod_registry_.do: | _ description/PodDescription |
      if description.fleet_id == fleet_id:
        result.add {
          "id": description.id,
          "name": description.name,
          "description": description.description,
        }
    return result

  pod_registry_descriptions_by_ids data/Map:
    pod_description_ids := data["_description_ids"]

    result := []
    pod_description_ids.do: | pod_description_id |
      description/PodDescription? := pod_registry_.get pod_description_id
      if description:
        result.add {
          "id": description.id,
          "name": description.name,
          "description": description.description,
        }
    return result

  pod_registry_descriptions_by_names data/Map:
    fleet_id := data["_fleet_id"]
    names := data["_names"]
    create_if_absent := data["_create_if_absent"]
    names_set := {}
    names_set.add_all names

    result := []
    pod_registry_.do: | _ description/PodDescription |
      if description.fleet_id == fleet_id and names_set.contains description.name:
        names_set.remove description.name
        result.add {
          "id": description.id,
          "name": description.name,
          "description": description.description,
        }

    if create_if_absent:
      names_set.do: | name/string |
        id := pod_description_ids_++
        pod_description := PodDescription
            --id=id
            --name=name
            --fleet_id=fleet_id
            --description=null
        pod_registry_[id] = pod_description
        result.add {
          "id": id,
          "name": name,
          "description": null,
        }

    return result

  pod_registry_pods data/Map:
    pod_description_id := data["_pod_description_id"]

    description/PodDescription := pod_registry_[pod_description_id]
    return pod_registry_pods_by_ids {
      "_fleet_id": description.fleet_id,
      "_pod_ids": description.pods.keys,
    }

  pod_registry_pods_by_ids data/Map:
    fleet_id := data["_fleet_id"]
    pod_ids := data["_pod_ids"]

    pod_ids_set := {}
    pod_ids_set.add_all pod_ids

    result := []
    pod_registry_.do: | _ description/PodDescription |
      if description.fleet_id == fleet_id:
        description.pods.do: | pod_id _ |
          if pod_ids_set.contains pod_id:
            result.add {
              "id": pod_id,
              "revision": description.pod_revisions[pod_id],
              "created_at": description.pod_created_ats[pod_id],
              "pod_description_id": description.id,
              "tags": description.pods[pod_id],
            }
    result.sort --in_place: | a b |
      -((Time.from_string a["created_at"]).compare_to (Time.from_string b["created_at"]))
    return result

  pod_registry_pod_ids_by_reference data/Map:
    fleet_id := data["_fleet_id"]
    references := data["_references"]

    names_to_descriptions := {:}
    pod_registry_.do: | _ description/PodDescription |
      if description.fleet_id == fleet_id:
        names_to_descriptions[description.name] = description

    result := []
    for i := 0; i < references.size; i++:
      reference := references[i]
      name := reference["name"]
      tag := reference.get "tag"
      revision := reference.get "revision"
      description/PodDescription? := names_to_descriptions.get name
      if description:
        if tag:
          description.pods.do: | pod_id tags |
            if tags.contains tag:
              result.add {
                "pod_id": pod_id,
                "name": name,
                "tag": tag,
              }
              continue
        else if revision:
          description.pod_revisions.do: | pod_id pod_revision |
            if pod_revision == revision:
              result.add {
                "pod_id": pod_id,
                "name": name,
                "revision": revision,
              }
              continue
        else:
          throw "Either tag or revision must be specified"

    return result
