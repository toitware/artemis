// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import http
import net
import net.tcp
import encoding.json
import encoding.base64
import monitor

main args:
  root_cmd := cli.Command "root"
    --long_help="""An http-based broker

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

class HttpBroker:
  port/int? := null

  configs := {:}
  images := {:}
  firmwares := {:}
  device_status := {:}

  // Map from device id to latch.
  waiting_for_events := {:}

  socket_/tcp.ServerSocket? := null

  constructor .port:

  close:
    if socket_:
      socket_.close
      socket_ = null

  /** Starts the server in a blocking way. */
  start port_latch/monitor.Latch?=null:
    network := net.open
    socket := network.tcp_listen (port or 0)
    port = socket.local_address.port
    if port_latch: port_latch.set port
    server := http.Server
    print "Listening on port $socket.local_address.port"
    server.listen socket:: | request/http.Request writer/http.ResponseWriter |
      data := json.decode_stream request.body
      command := data["command"]

      if command == "get_config": reply writer: get_config data["data"]
      else if command == "update_config": reply writer: update_config data["data"]
      else if command == "upload_image": reply writer: upload_image data["data"]
      else if command == "upload_firmware": reply writer: upload_firmware data["data"]
      else if command == "download_firmware": reply writer: download_firmware data["data"]
      else if command == "report_status": reply writer: report_status data["data"]
      else if command == "get_event": reply writer: get_event data["data"]
      else:
        print "Unknown command: $command"
        throw "BAD COMMAND $command"


  reply writer/http.ResponseWriter [block]:
    response_data := null
    exception := catch --trace: response_data = block.call
    if exception:
      writer.write (json.encode {
        "success": false,
        "error": "$exception",
      })
    else:
      writer.write (json.encode {
        "success": true,
        "data": response_data
      })

  get_config data/Map:
    device_id := data["device_id"]
    config := configs.get device_id

  update_config data/Map:
    device_id := data["device_id"]
    configs[device_id] = data["config"]
    notify_device device_id "config_updated"

  upload_image data/Map:
    app_id := data["app_id"]
    bits := data["bits"]
    images["$app_id-$bits"] = data["content"]

  upload_firmware data/Map:
    firmware_id := data["firmware_id"]
    firmwares[firmware_id] = data["content"]

  download_firmware data/Map:
    firmware_id := data["firmware_id"]
    offset := (data.get "offset") or 0
    encoded_firmware := firmwares[firmware_id]
    encoded_content := ?
    if offset == 0:
      encoded_content = encoded_firmware
    else:
      bytes := base64.decode encoded_firmware
      encoded_content = base64.encode bytes[offset..]
    return {
      "content": encoded_content
    }

  report_status data/Map:
    device_id := data["device_id"]
    device_status[device_id] = data["status"]
    notify_device device_id "status_updated"

  get_event data/Map:
    device_id := data["device_id"]
    latch := monitor.Latch
    waiting_for_events[device_id] = latch
    event_type := latch.get
    if event_type == "config_updated":
      return {
        "event_type": "config_updated",
        "config": configs[device_id]
      }
    else if event_type == "status_updated":
      return {
        "event_type": "status_updated",
        "status": device_status[device_id]
      }
    else:
      throw "Unknown event type: $event_type"

  notify_device device_id/string event_type/string:
    latch/monitor.Latch? := waiting_for_events.get device_id
    if latch:
      waiting_for_events.remove device_id
      latch.set event_type

