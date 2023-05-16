// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
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

  // Map from device-id to latch.
  waiting_for_events/Map := {:}
  /**
  The state revisions for each device.
  Every time the state of a device changes (which is signaled through a
    $notify_device call), the revision is incremented.

  When a client subscribes to events, it sends its current revision. If the
    revision is not the same as the one stored here, then the client is
    informed that it needs to reconcile its state.
  */
  state_revision_/Map := {:}

  /* Pod description related fields. */
  pod_description_ids_ := 0
  pod_registry_/Map ::= {:}  // Map from pod-description ID to $PodDescription object.

  constructor port/int:
    super port

  run_command command/string data _ -> any:
    if command == "notify_created": return notify_created data
    if command == "get_goal": return get_goal data
    if command == "get_goal_no_event": return get_goal_no_event data
    if command == "update_goal": return update_goal data
    if command == "upload": return upload data
    if command == "download": return download data
    if command == "report_state": return report_state data
    if command == "get_state": return get_state data
    if command == "get_event": return get_event data
    if command == "report_event": return report_event data
    if command == "get_events": return get_events data
    if command == "get_devices": return get_devices data

    if command == "pod_registry_description_upsert": return pod_registry_description_upsert data
    if command == "pod_registry_add": return pod_registry_add data
    if command == "pod_registry_tag_set": return pod_registry_tag_set data
    if command == "pod_registry_tag_remove": return pod_registry_tag_remove data
    if command == "pod_registry_descriptions": return pod_registry_descriptions data
    if command == "pod_registry_descriptions_by_ids": return pod_registry_descriptions_by_ids data
    if command == "pod_registry_descriptions_by_names": return pod_registry_descriptions_by_names data
    if command == "pod_registry_pods": return pod_registry_pods data
    if command == "pod_registry_pods_by_ids": return pod_registry_pods_by_ids data
    if command == "pod_registry_pod_ids_by_names_tags": return pod_registry_pod_ids_by_names_tags data

    print "Unknown command: $command"
    throw "BAD COMMAND $command"

  notify_created data/Map:
    device_id := data["device_id"]
    state := data["state"]
    device_states_[device_id] = state

  /** Backdoor for creating a new device. */
  create_device --device_id/string --state/Map:
    device_states_[device_id] = state

  get_goal data/Map -> Map?:
    device_id := data["device_id"]
    // Automatically adds an event.
    result := get_goal_no_event data
    report_event device_id "get-goal" null
    return result

  get_goal_no_event data/Map -> Map?:
    device_id := data["device_id"]
    current_revision := state_revision_.get device_id --init=: 0
    return {
      "state_revision": current_revision,
      "goal": device_goals_.get device_id,
    }

  update_goal data/Map:
    device_id := data["device_id"]
    device_goals_[device_id] = data["goal"]
    print "Updating goal state for $device_id to $device_goals_[device_id] and notifying."
    notify_device device_id "goal_updated"

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
      return PartialResponse bytes[offset..part_end] bytes.size
    return bytes

  report_state data/Map:
    device_id := data["device_id"]
    device_states_[device_id] = data["state"]
    // Automatically adds an event.
    report_event device_id "update-state" data["state"]

  get_state data/Map:
    device_id := data["device_id"]
    return get_state --device_id=device_id

  get_state --device_id/string -> Map?:
    return device_states_.get device_id

  get_event data/Map:
    device_id := data["device_id"]
    known_revision := data["state_revision"]
    current_revision := state_revision_.get device_id --init=: 0

    if current_revision != known_revision:
      // The client and the server are out of sync. Inform the client
      // that it needs to reconcile.
      return {
        "event_type": "out_of_sync",
        "state_revision": current_revision,
      }

    event_type := null
    latch := monitor.Latch
    waiting_for_events[device_id] = latch
    catch: with_timeout (Duration --m=1): event_type = latch.get

    if not event_type:
      return { "event_type": "timed_out" }
    if event_type != "goal_updated":
      throw "Unknown event type: $event_type"

    report_event device_id "get-goal" null
    return {
      "event_type": event_type,
      "state_revision": state_revision_[device_id],
      "goal": device_goals_.get device_id,
    }

  notify_device device_id/string event_type/string:
    latch/monitor.Latch? := waiting_for_events.get device_id
    state_revision_.update device_id --if_absent=0: it + 1
    if latch:
      waiting_for_events.remove device_id
      latch.set event_type

  remove_device device_id/string:
    device_states_.remove device_id
    device_goals_.remove device_id
    state_revision_.remove device_id
    waiting_for_events.remove device_id

  report_event data/Map:
    device_id := data["device_id"]
    event_type := data["type"]
    payload := data["data"]
    report_event device_id event_type payload

  report_event device_id/string event_type/string payload/any:
    event_list := events_.get device_id --init=:[]
    event_list.add {
      "event_type": event_type,
      "data": payload,
      "timestamp": Time.now,
    }

  get_events data/Map:
    types := data["types"]
    device_ids := data["device_ids"]
    limit := data.get "limit"
    since_ns := data.get "since"
    since_time := since_ns and Time.epoch --ns=since_ns

    type_set := {}
    if types: type_set.add_all types

    result := {:}
    device_ids.do: | device_id |
      if not device_states_.contains device_id:
        throw "Unknown device: $device_id"
      device_result := []
      events := events_.get device_id --if_absent=:[]
      count := 0
      // Iterate backwards to get the most recent events first.
      for i := events.size - 1; i >= 0; i--:
        event := events[i]
        if types and not type_set.contains event["event_type"]: continue
        if since_time and event["timestamp"] <= since_time: continue
        device_result.add {
          "type": event["event_type"],
          "timestamp_ns": (event["timestamp"] as Time).ns_since_epoch,
          "data": event["data"],
        }
        count++
        if limit and count >= limit: break
      if not device_result.is_empty: result[device_id] = device_result
    return result

  get_devices data/Map:
    device_ids := data["device_ids"]
    result := {:}
    device_ids.do: | device_id |
      state := device_states_.get device_id
      goal := device_goals_.get device_id
      if not goal and not state: continue.do
      result[device_id] = {
        "state": state,
        "goal": goal,
      }
    return result

  clear_events:
    events_.clear

  pod_registry_description_upsert data/Map:
    fleet_id := data["fleet_id"]
    organization_id := data["organization_id"]
    name := data["name"]
    description := data.get "description"

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
    pod_description_id := data["pod_description_id"]
    pod_id := data["pod_id"]
    description/PodDescription := pod_registry_[pod_description_id]
    revision := description.revision_counter + 1
    created_at := Time.now.utc.to_iso8601_string
    description.revision_counter++
    description.pods[pod_id] = []
    description.pod_revisions[pod_id] = revision
    description.pod_created_ats[pod_id] = created_at

  pod_registry_tag_set data/Map:
    pod_description_id := data["pod_description_id"]
    pod_id := data["pod_id"]
    tag := data["tag"]
    force := data["force"]

    description/PodDescription := pod_registry_[pod_description_id]
    description.pods.do: | _ tags |
      if force:
        tags.remove tag
      else if tags.contains tag:
        throw "Tag already exists: $tag"
    description.pods[pod_id].add tag

  pod_registry_tag_remove data/Map:
    pod_description_id := data["pod_description_id"]
    tag := data["tag"]

    description/PodDescription := pod_registry_[pod_description_id]
    description.pods.do: | _ tags/List |
      if tags.contains tag:
        tags.remove tag
        return

  pod_registry_descriptions data/Map:
    fleet_id := data["fleet_id"]

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
    pod_description_ids := data["ids"]

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
    fleet_id := data["fleet_id"]
    names := data["names"]
    create_if_absent := data["create_if_absent"]
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
    pod_description_id := data["pod_description_id"]

    description/PodDescription := pod_registry_[pod_description_id]
    return pod_registry_pods_by_ids {
      "fleet_id": description.fleet_id,
      "pod_ids": description.pods.keys,
    }

  pod_registry_pods_by_ids data/Map:
    fleet_id := data["fleet_id"]
    pod_ids := data["pod_ids"]

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

  pod_registry_pod_ids_by_names_tags data/Map:
    fleet_id := data["fleet_id"]
    names_tags := data["names_tags"]

    names_to_descriptions := {:}
    pod_registry_.do: | _ description/PodDescription |
      if description.fleet_id == fleet_id:
        names_to_descriptions[description.name] = description

    result := []
    names_tags.do: | name_tag |
      name := name_tag["name"]
      tag := name_tag["tag"]
      description/PodDescription? := names_to_descriptions.get name
      if description:
        description.pods.do: | pod_id tags |
          if tags.contains tag:
            result.add {
              "pod_id": pod_id,
              "name": name,
              "tag": tag,
            }

    return result
