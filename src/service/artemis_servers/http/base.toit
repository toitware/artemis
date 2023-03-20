// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import http
import log
import net
import supabase.utils

import ..artemis_server
import ....shared.server_config

class ArtemisServerServiceHttp implements ArtemisServerService:
  server_config_/ServerConfigHttpToit
  hardware_id_/string

  constructor .server_config_ --hardware_id/string:
    hardware_id_ = hardware_id

  check_in network/net.Interface logger/log.Logger -> none:
    send_request_ network "check-in" {
      "hardware_id": hardware_id_,
      "data": { "type": "ping" },
    }

  send_request_ network/net.Interface command/string data/Map -> any:
    client := http.Client network

    encoded := ubjson.encode {
      "command": command,
      "data": data,
    }
    response := client.post encoded
        --host=server_config_.host
        --port=server_config_.port
        --path="/"

    if response.status_code != 200:
      throw "HTTP error: $response.status_code $response.status_message"

    return ubjson.decode (utils.read_all response.body)
