// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import encoding.base64
import http
import net

class HttpConnection_:
  network_/net.Interface? := ?
  host_/string
  port_/int

  constructor .host_ .port_:
    network_ = net.open

  close:
    if network_:
      network_.close
      network_ = null

  is_closed -> bool:
    return network_ == null

  send_request command/string data/Map:
    if is_closed: throw "CLOSED"
    client := http.Client network_

    encoded := ubjson.encode {
      "command": command,
      "data": data,
    }
    response := client.post encoded --host=host_ --port=port_ --path="/"
    if response.status_code != 200:
      throw "HTTP error: $response.status_code $response.status_message"

    encoded_response := #[]
    while chunk := response.body.read:
      encoded_response += chunk
    decoded := ubjson.decode encoded_response
    if not (decoded.get "success"):
      throw "Broker error: $(decoded.get "error")"

    return decoded["data"]
