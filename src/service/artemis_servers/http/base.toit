// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.json
import http
import log
import net
import uuid

import ..artemis_server
import ....shared.server_config
import ....shared.utils as utils
import ....shared.constants show *

class ArtemisServerServiceHttp implements ArtemisServerService:
  server_config_/ServerConfigHttp
  hardware_id_/uuid.Uuid

  constructor .server_config_ --hardware_id/uuid.Uuid:
    hardware_id_ = hardware_id

  check_in network/net.Interface logger/log.Logger -> none:
    send_request_ network COMMAND_CHECK_IN_ {
      "hardware_id": "$hardware_id_",
      "data": { "type": "ping" },
    }

  send_request_ network/net.Interface command/int data/Map -> any:
    client := http.Client network
    try:
      encoded := #[command] + (json.encode data)

      headers := null
      if server_config_.device_headers:
        headers = http.Headers
        server_config_.device_headers.do: | key value |
          headers.add key value
      response := client.post encoded
          --host=server_config_.host
          --port=server_config_.port
          --path=server_config_.path
          --headers=headers

      if response.status_code != http.STATUS_OK:
        throw "HTTP error: $response.status_code $response.status_message"

      return json.decode_stream response.body
    finally:
      client.close
