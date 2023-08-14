// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.json
import http
import log
import net
import uuid

import ..artemis-server
import ....shared.server-config
import ....shared.utils as utils
import ....shared.constants show *

class ArtemisServerServiceHttp implements ArtemisServerService:
  server-config_/ServerConfigHttp
  hardware-id_/uuid.Uuid

  constructor .server-config_ --hardware-id/uuid.Uuid:
    hardware-id_ = hardware-id

  check-in network/net.Interface logger/log.Logger -> none:
    send-request_ network COMMAND-CHECK-IN_ {
      "hardware_id": "$hardware-id_",
      "data": { "type": "ping" },
    }

  send-request_ network/net.Interface command/int data/Map -> any:
    client := http.Client network
    try:
      encoded := #[command] + (json.encode data)

      headers := null
      if server-config_.device-headers:
        headers = http.Headers
        server-config_.device-headers.do: | key value |
          headers.add key value
      response := client.post encoded
          --host=server-config_.host
          --port=server-config_.port
          --path=server-config_.path
          --headers=headers

      if response.status-code != http.STATUS-OK:
        throw "HTTP error: $response.status-code $response.status-message"

      return json.decode-stream response.body
    finally:
      client.close
