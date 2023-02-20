// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import monitor

import .base

main args:
  root_cmd := cli.Command "root"
    --long_help="""An HTTP-based broker

      Can be used to let devices and the CLI communicate with each other.
      This server keeps data in memory and should thus only be used for
      testing.
      """
    --options=[
      cli.OptionInt "port" --short_name="p"
          --short_help="The port to listen on"
    ]
    --run=:: | parsed/cli.Parsed |
      broker := HttpBroker parsed["port"]
      broker.start

  root_cmd.run args

class HttpBroker extends HttpServer:
  images := {:}
  firmwares := {:}
  device_states := {:}
  device_goals := {:}

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
  state_revision/Map := {:}

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
    print "Unknown command: $command"
    throw "BAD COMMAND $command"

  notify_created data/Map:
    device_id := data["device_id"]
    state := data["state"]
    device_states[device_id] = state

  /** Backdoor for creating a new device. */
  create_device --device_id/string --state/Map:
    device_states[device_id] = state

  get_goal data/Map -> Map?:
    device_id := data["device_id"]
    config := device_goals.get device_id
    return config

  update_goal data/Map:
    device_id := data["device_id"]
    device_goals[device_id] = data["goal"]
    print "Updating goal state for $device_id to $device_goals[device_id] and notifying."
    notify_device device_id "goal_updated"

  upload_image data/Map:
    organization_id := data["organization_id"]
    app_id := data["app_id"]
    word_size := data["word_size"]
    images["$(organization_id)-$(app_id)-$word_size"] = data["content"]

  download_image data/Map:
    organization_id := data["organization_id"]
    app_id := data["app_id"]
    word_size := data["word_size"]
    return images["$(organization_id)-$(app_id)-$word_size"]

  upload_firmware data/Map:
    organization_id := data["organization_id"]
    firmware_id := data["firmware_id"]
    firmwares["$(organization_id)-$firmware_id"] = data["content"]

  download_firmware data/Map:
    organization_id := data["organization_id"]
    firmware_id := data["firmware_id"]
    offset := (data.get "offset") or 0
    firmware := firmwares["$(organization_id)-$firmware_id"]
    return firmware[offset..]

  report_state data/Map:
    device_id := data["device_id"]
    device_states[device_id] = data["state"]

  get_state data/Map:
    device_id := data["device_id"]
    return get_state --device_id=device_id

  get_state --device_id/string -> Map?:
    return device_states.get device_id

  get_event data/Map:
    device_id := data["device_id"]
    known_revision := data["state_revision"]
    current_revision := state_revision.get device_id --init=:0

    if current_revision != known_revision:
      // The client and the server are out of sync. Inform the client that it needs
      // to reconcile.
      return {
        "event_type": "out_of_sync",
        "state_revision": current_revision,
      }

    latch := monitor.Latch
    waiting_for_events[device_id] = latch
    event_type := latch.get
    message := {
      "event_type": event_type,
      "state_revision": state_revision[device_id],
    }
    if event_type == "goal_updated":
      message["goal"] = device_goals[device_id]
    else if event_type == "state_updated":
      message["state"] = device_states[device_id]
    else:
      throw "Unknown event type: $event_type"
    return message

  notify_device device_id/string event_type/string:
    latch/monitor.Latch? := waiting_for_events.get device_id
    state_revision.update device_id --if_absent=0: it + 1
    if latch:
      waiting_for_events.remove device_id
      latch.set event_type

  remove_device device_id/string:
    device_states.remove device_id
    device_goals.remove device_id
    state_revision.remove device_id
    waiting_for_events.remove device_id
