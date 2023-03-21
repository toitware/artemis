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

class HttpBroker extends HttpServer:
  images_/Map := {:}
  firmwares_/Map := {:}
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

  constructor port/int:
    super port

  run_command command/string data _ -> any:
    if command == "notify_created": return notify_created data
    if command == "get_goal": return get_goal data
    if command == "update_goal": return update_goal data
    if command == "upload_image": return upload_image data
    if command == "download_image": return download_image data
    if command == "upload_firmware": return upload_firmware data
    if command == "download_firmware": return download_firmware data
    if command == "report_state": return report_state data
    if command == "get_state": return get_state data
    if command == "get_event": return get_event data
    if command == "report_event": return report_event data
    if command == "get_events": return get_events data
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
    current_revision := state_revision_.get device_id --init=: 0
    // Automatically adds an event.
    report_event device_id "goal_updated" null
    return {
      "state_revision": current_revision,
      "goal": device_goals_.get device_id,
    }

  update_goal data/Map:
    device_id := data["device_id"]
    device_goals_[device_id] = data["goal"]
    print "Updating goal state for $device_id to $device_goals_[device_id] and notifying."
    notify_device device_id "goal_updated"

  upload_image data/Map:
    organization_id := data["organization_id"]
    app_id := data["app_id"]
    word_size := data["word_size"]
    images_["$(organization_id)-$(app_id)-$word_size"] = data["content"]

  download_image data/Map:
    organization_id := data["organization_id"]
    app_id := data["app_id"]
    word_size := data["word_size"]
    return images_["$(organization_id)-$(app_id)-$word_size"]

  upload_firmware data/Map:
    organization_id := data["organization_id"]
    firmware_id := data["firmware_id"]
    firmwares_["$(organization_id)-$firmware_id"] = data["content"]

  download_firmware data/Map:
    organization_id := data["organization_id"]
    firmware_id := data["firmware_id"]
    offset := (data.get "offset") or 0
    size := data.get "size"
    firmware := firmwares_["$(organization_id)-$firmware_id"]
    part_end := ?
    if size:
      part_end = min firmware.size (offset + size)
    else:
      part_end = firmware.size
    if offset != 0 or part_end != firmware.size:
      return PartialResponse firmware[offset..part_end] firmware.size
    return firmware

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

  clear_events:
    events_.clear
