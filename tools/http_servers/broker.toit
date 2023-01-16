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
  configs := {:}
  images := {:}
  firmwares := {:}
  device_status := {:}

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
    if command == "get_config": return get_config data
    else if command == "update_config": return update_config data
    else if command == "upload_image": return upload_image data
    else if command == "download_image": return download_image data
    else if command == "upload_firmware": return upload_firmware data
    else if command == "download_firmware": return download_firmware data
    else if command == "report_status": return report_status data
    else if command == "get_event": return get_event data
    else:
      print "Unknown command: $command"
      throw "BAD COMMAND $command"

  get_config data/Map -> Map:
    device_id := data["device_id"]
    config := configs.get device_id
    return config or {:}

  update_config data/Map:
    device_id := data["device_id"]
    configs[device_id] = data["config"]
    print "Updating config for $device_id to $configs[device_id] and notifying."
    notify_device device_id "config_updated"

  upload_image data/Map:
    app_id := data["app_id"]
    bits := data["bits"]
    images["$app_id-$bits"] = data["content"]

  download_image data/Map:
    app_id := data["app_id"]
    bits := data["bits"]
    return images["$app_id-$bits"]

  upload_firmware data/Map:
    firmware_id := data["firmware_id"]
    firmwares[firmware_id] = data["content"]

  download_firmware data/Map:
    firmware_id := data["firmware_id"]
    offset := (data.get "offset") or 0
    firmware := firmwares[firmware_id]
    return firmware[offset..]

  report_status data/Map:
    device_id := data["device_id"]
    device_status[device_id] = data["status"]
    notify_device device_id "status_updated"

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
      "state_revision": ++state_revision[device_id],
    }
    if event_type == "config_updated":
      message["config"] = configs[device_id]
    else if event_type == "status_updated":
      message["status"] = device_status[device_id]
    else:
      throw "Unknown event type: $event_type"
    return message

  notify_device device_id/string event_type/string:
    latch/monitor.Latch? := waiting_for_events.get device_id
    if latch:
      waiting_for_events.remove device_id
      latch.set event_type
