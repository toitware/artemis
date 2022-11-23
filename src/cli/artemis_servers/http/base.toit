// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import encoding.ubjson
import http
import log
import net
import encoding.json

import ..artemis_server

import ....shared.server_config

class ArtemisServerCliHttpToit implements ArtemisServerCli:
  client_/http.Client
  server_config_/ServerConfigHttpToit

  constructor network/net.Interface .server_config_/ServerConfigHttpToit:
    client_ = http.Client network

  is_closed -> bool:
    // TODO(florian): we need a newer http client to be able to
    // ask whether it's closed.
    return false

  close -> none:
    // TODO(florian): we need a newer http client to be able to close it.

  create_device_in_fleet --fleet_id/string --device_id/string -> string:
    map := {
      "fleet": fleet_id,
    }
    if device_id != "": map["alias"] = device_id

    return send_request_ "create-device-in-fleet" map

  notify_created --hardware_id/string -> none:
    send_request_ "notify-created" {
      "hardware_id": hardware_id,
      "data": { "type": "created" },
    }

  send_request_ command/string data/Map -> any:
    encoded := ubjson.encode {
      "command": command,
      "data": data,
    }
    response := client_.post encoded
        --host=server_config_.host
        --port=server_config_.port
        --path="/"

    if response.status_code != 200:
      throw "HTTP error: $response.status_code $response.status_message"

    encoded_response := #[]
    while chunk := response.body.read:
      encoded_response += chunk
    decoded := ubjson.decode encoded_response
    if not (decoded.get "success"):
      throw "Broker error: $(decoded.get "error")"

    return decoded["data"]
