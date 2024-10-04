// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import cli show *
import encoding.json
import monitor

import .base
import .constants

main args:
  root-cmd := Command "root"
    --help="""An HTTP-based broker.

      Can be used to let devices and the CLI communicate with each other.
      This server keeps data in memory and should thus only be used for
      testing.
      """
    --options=[
      OptionInt "port" --short-name="p"
          --help="The port to listen on."
    ]
    --run=:: | invocation/Invocation |
      broker := HttpBroker invocation["port"]
      broker.start

  root-cmd.run args

class PodDescription:
  id/int
  name/string
  description/string? := ?
  fleet-id/string
  pods/Map  // Map from pod-id to list of tags.
  pod-revisions/Map // Map from pod-id to revision.
  pod-created-ats/Map // Map from pod-id to created-at timestamp.
  revision-counter/int := 0

  constructor --.id --.fleet-id --.name --.description:
    pods = {:}
    pod-revisions = {:}
    pod-created-ats = {:}

class HttpBroker extends HttpServer:
  storage_/Map := {:}
  device-states_/Map := {:}
  device-goals_/Map := {:}
  events_/Map := {:}  // Map from device-id to list of events.

  /* Pod description related fields. */
  pod-description-ids_ := 0
  pod-registry_/Map ::= {:}  // Map from pod-description ID to $PodDescription object.

  is-stopped_/bool := false

  constructor port/int:
    super port

  run-command command/int encoded/ByteArray _ -> any:
    if is-stopped_: throw "Broker is stopped."

    data := ?
    if command == COMMAND-UPLOAD_:
      path-end := encoded.index-of '\0'
      path := encoded[0..path-end].to-string
      content := encoded[path-end + 1 ..]
      data = {
        "path": path,
        "content": content,
      }
      print "$Time.now: Broker request upload ($command) with path=$path and $content.size bytes."
    else:
      data = json.decode encoded
      print "$Time.now: Broker request $(BROKER-COMMAND-TO-STRING.get command) ($command) with $data."

    if command == COMMAND-UPLOAD_: return upload data
    if command == COMMAND-DOWNLOAD_: return download data
    if command == COMMAND-DOWNLOAD-PRIVATE_: return download data
    if command == COMMAND-UPDATE-GOAL_: return update-goal data
    if command == COMMAND-UPDATE-GOALS_: return update-goals data
    if command == COMMAND-GET-DEVICES_: return get-devices data
    if command == COMMAND-NOTIFY-BROKER-CREATED_: return notify-created data
    if command == COMMAND-GET-EVENTS_: return get-events data
    if command == COMMAND-GET-GOAL_: return get-goal data
    if command == COMMAND-REPORT-STATE_: return report-state data
    if command == COMMAND-REPORT-EVENT_: return report-event data

    if command == COMMAND-POD-REGISTRY-DESCRIPTION-UPSERT_:
      return pod-registry-description-upsert data
    if command == COMMAND-POD-REGISTRY-ADD_:
      return pod-registry-add data
    if command == COMMAND-POD-REGISTRY-TAG-SET_:
      return pod-registry-tag-set data
    if command == COMMAND-POD-REGISTRY-TAG-REMOVE_:
      return pod-registry-tag-remove data
    if command == COMMAND-POD-REGISTRY-DESCRIPTIONS_:
      return pod-registry-descriptions data
    if command == COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-IDS_:
      return pod-registry-descriptions-by-ids data
    if command == COMMAND-POD-REGISTRY-DESCRIPTIONS-BY-NAMES_:
      return pod-registry-descriptions-by-names data
    if command == COMMAND-POD-REGISTRY-PODS_:
      return pod-registry-pods data
    if command == COMMAND-POD-REGISTRY-PODS-BY-IDS_:
      return pod-registry-pods-by-ids data
    if command == COMMAND-POD-REGISTRY-POD-IDS-BY-REFERENCE_:
      return pod-registry-pod-ids-by-reference data
    if command == COMMAND-POD-REGISTRY-DELETE-DESCRIPTIONS_:
      return pod-registry-delete-descriptions data
    if command == COMMAND-POD-REGISTRY-DELETE_:
      return pod-registry-delete data

    print "Unknown command: $command"
    throw "BAD COMMAND $command"

  stop -> none:
    is-stopped_ = true

  notify-created data/Map:
    device-id := data["_device_id"]
    state := data["_state"]
    device-states_[device-id] = state

  /** Backdoor for creating a new device. */
  create-device --device-id/string --state/Map:
    device-states_[device-id] = state

  get-goal data/Map -> Map?:
    device-id := data["_device_id"]
    // Automatically adds an event.
    result := device-goals_.get device-id
    report-event device-id "get-goal" null
    return result

  update-goal data/Map:
    device-id := data["_device_id"]
    device-goals_[device-id] = data["_goal"]
    print "Updating goal state for $device-id to $device-goals_[device-id]."

  update-goals data/Map:
    device-ids := data["_device_ids"]
    goals := data["_goals"]
    device-ids.size.repeat: | i |
      device-id := device-ids[i]
      goal := goals[i]
      device-goals_[device-id] = goal
      print "Updating goal state for $device-id to $goal."

  upload data/Map:
    path := data["path"]
    storage_[path] = data["content"]

  download data/Map:
    path := data["path"]
    bytes := storage_[path]
    offset := (data.get "offset") or 0
    size := data.get "size"
    part-end := ?
    if size:
      part-end = min bytes.size (offset + size)
    else:
      part-end = bytes.size
    if offset != 0 or part-end != bytes.size:
      return BinaryResponse bytes[offset..part-end] bytes.size
    return BinaryResponse bytes bytes.size

  report-state data/Map:
    device-id := data["_device_id"]
    device-states_[device-id] = data["_state"]
    // Automatically adds an event.
    report-event device-id "update-state" data["_state"]

  get-state --device-id/string -> Map?:
    return device-states_.get device-id

  remove-device device-id/string:
    device-states_.remove device-id
    device-goals_.remove device-id

  report-event data/Map:
    device-id := data["_device_id"]
    event-type := data["_type"]
    payload := data["_data"]
    report-event device-id event-type payload

  report-event device-id/string event-type/string payload/any:
    print "report-event: $device-id $event-type $payload"
    event-list := events_.get device-id --init=:[]
    event-list.add {
      "event_type": event-type,
      "data": payload,
      "timestamp": Time.now,
    }

  get-events data/Map:
    types := data["_types"]
    device-ids := data["_device_ids"]
    limit := data.get "_limit"
    since := data.get "_since"
    since-time := since and Time.parse since

    type-set := {}
    if types: type-set.add-all types

    result := []
    device-ids.do: | device-id |
      if not device-states_.contains device-id:
        throw "Unknown device: $device-id"
      events := events_.get device-id --if-absent=:[]
      count := 0
      // Iterate backwards to get the most recent events first.
      for i := events.size - 1; i >= 0; i--:
        event := events[i]
        if types and not type-set.contains event["event_type"]: continue
        if since-time and event["timestamp"] <= since-time: continue
        result.add {
          "device_id": device-id,
          "type": event["event_type"],
          "ts": "$((event["timestamp"] as Time).utc.to-iso8601-string)",
          "data": event["data"],
        }
        count++
        if limit and count >= limit: break
    return result

  get-devices data/Map:
    device-ids := data["_device_ids"]
    result := []
    device-ids.do: | device-id |
      state := device-states_.get device-id
      goal := device-goals_.get device-id
      if not goal and not state: continue.do
      result.add {
        "device_id": device-id,
        "state": state,
        "goal": goal,
      }
    return result

  clear-events:
    events_.clear

  pod-registry-description-upsert data/Map:
    fleet-id := data["_fleet_id"]
    organization-id := data["_organization_id"]
    name := data["_name"]
    description := data.get "_description"

    pod-registry_.do: | id pod-description/PodDescription |
      if pod-description.fleet-id == fleet-id and
          pod-description.name == name:
        pod-description.description = description
        return id

    id := pod-description-ids_++
    pod-description := PodDescription
        --id=id
        --name=name
        --description=description
        --fleet-id=fleet-id
    pod-registry_[id] = pod-description
    return id

  pod-registry-delete-descriptions data/Map:
    fleet-id := data["_fleet_id"]
    description-ids := data["_description_ids"]
    description-ids.do: | description-id |
      pod-registry_.remove description-id

  pod-registry-add data/Map:
    pod-description-id := data["_pod_description_id"]
    pod-id := data["_pod_id"]
    description/PodDescription := pod-registry_[pod-description-id]
    revision := description.revision-counter + 1
    created-at := Time.now.utc.to-iso8601-string
    description.revision-counter++
    description.pods[pod-id] = []
    description.pod-revisions[pod-id] = revision
    description.pod-created-ats[pod-id] = created-at

  pod-registry-delete data/Map:
    fleet-id := data["_fleet_id"]
    pod-ids := data["_pod_ids"]

    pod-registry_.do: | id description/PodDescription |
      if description.fleet-id == fleet-id:
        description.pods.do: | pod-id |
          pod-ids.do: | pod-id |
            description.pods.remove pod-id
            description.pod-revisions.remove pod-id
            description.pod-created-ats.remove pod-id

  pod-registry-tag-set data/Map:
    pod-description-id := data["_pod_description_id"]
    pod-id := data["_pod_id"]
    tag := data["_tag"]
    force := data["_force"]

    description/PodDescription := pod-registry_[pod-description-id]
    description.pods.do: | _ tags |
      if force:
        tags.remove tag
      else if tags.contains tag:
        throw "Tag already exists: $tag"
    description.pods[pod-id].add tag

  pod-registry-tag-remove data/Map:
    pod-description-id := data["_pod_description_id"]
    tag := data["_tag"]

    description/PodDescription := pod-registry_[pod-description-id]
    description.pods.do: | _ tags/List |
      if tags.contains tag:
        tags.remove tag
        return

  pod-registry-descriptions data/Map:
    fleet-id := data["_fleet_id"]

    result := []
    pod-registry_.do: | _ description/PodDescription |
      if description.fleet-id == fleet-id:
        result.add {
          "id": description.id,
          "name": description.name,
          "description": description.description,
        }
    return result

  pod-registry-descriptions-by-ids data/Map:
    pod-description-ids := data["_description_ids"]

    result := []
    pod-description-ids.do: | pod-description-id |
      description/PodDescription? := pod-registry_.get pod-description-id
      if description:
        result.add {
          "id": description.id,
          "name": description.name,
          "description": description.description,
        }
    return result

  pod-registry-descriptions-by-names data/Map:
    fleet-id := data["_fleet_id"]
    names := data["_names"]
    create-if-absent := data["_create_if_absent"]
    names-set := {}
    names-set.add-all names

    result := []
    pod-registry_.do: | _ description/PodDescription |
      if description.fleet-id == fleet-id and names-set.contains description.name:
        names-set.remove description.name
        result.add {
          "id": description.id,
          "name": description.name,
          "description": description.description,
        }

    if create-if-absent:
      names-set.do: | name/string |
        id := pod-description-ids_++
        pod-description := PodDescription
            --id=id
            --name=name
            --fleet-id=fleet-id
            --description=null
        pod-registry_[id] = pod-description
        result.add {
          "id": id,
          "name": name,
          "description": null,
        }

    return result

  pod-registry-pods data/Map:
    pod-description-id := data["_pod_description_id"]

    description/PodDescription := pod-registry_[pod-description-id]
    return pod-registry-pods-by-ids {
      "_fleet_id": description.fleet-id,
      "_pod_ids": description.pods.keys,
    }

  pod-registry-pods-by-ids data/Map:
    fleet-id := data["_fleet_id"]
    pod-ids := data["_pod_ids"]

    pod-ids-set := {}
    pod-ids-set.add-all pod-ids

    result := []
    pod-registry_.do: | _ description/PodDescription |
      if description.fleet-id == fleet-id:
        description.pods.do: | pod-id _ |
          if pod-ids-set.contains pod-id:
            result.add {
              "id": pod-id,
              "revision": description.pod-revisions[pod-id],
              "created_at": description.pod-created-ats[pod-id],
              "pod_description_id": description.id,
              "tags": description.pods[pod-id],
            }
    result.sort --in-place: | a b |
      -((Time.parse a["created_at"]).compare-to (Time.parse b["created_at"]))
    return result

  pod-registry-pod-ids-by-reference data/Map:
    fleet-id := data["_fleet_id"]
    references := data["_references"]

    names-to-descriptions := {:}
    pod-registry_.do: | _ description/PodDescription |
      if description.fleet-id == fleet-id:
        names-to-descriptions[description.name] = description

    result := []
    for i := 0; i < references.size; i++:
      reference := references[i]
      name := reference["name"]
      tag := reference.get "tag"
      revision := reference.get "revision"
      description/PodDescription? := names-to-descriptions.get name
      if description:
        if tag:
          description.pods.do: | pod-id tags |
            if tags.contains tag:
              result.add {
                "pod_id": pod-id,
                "name": name,
                "tag": tag,
              }
              continue
        else if revision:
          description.pod-revisions.do: | pod-id pod-revision |
            if pod-revision == revision:
              result.add {
                "pod_id": pod-id,
                "name": name,
                "revision": revision,
              }
              continue
        else:
          throw "Either tag or revision must be specified"

    return result
