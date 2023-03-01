// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import encoding.base64
import http
import net
import reader show Reader

STATUS_IM_A_TEAPOT ::= 418

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

  send_request command/string data/Map -> any:
    payload := {
      "command": command,
      "data": data,
    }

    send_request_ payload: | reader/Reader |
      encoded_response := #[]
      while chunk := reader.read:
        encoded_response += chunk
      decoded := ubjson.decode encoded_response
      return decoded
    unreachable

  send_binary_request command/string data/Map [block] -> none:
    payload :=  {
      "command": command,
      "data": data,
      "binary": true,
    }
    send_request_ payload block

  send_request_ payload/Map [block] -> none:
    if is_closed: throw "CLOSED"
    client := http.Client network_
    encoded := ubjson.encode payload
    response := client.post encoded --host=host_ --port=port_ --path="/"

    if response.status_code == STATUS_IM_A_TEAPOT:
      encoded_response := #[]
      while chunk := response.body.read:
        encoded_response += chunk
      decoded := ubjson.decode encoded_response
      throw "Broker error: $decoded"

    if response.status_code != 200:
      throw "HTTP error: $response.status_code $response.status_message"

    range := response.headers.single "Content-Range"
    total_size := 0
    if range:
      divider := range.index_of "/"
      total_size = int.parse range[divider + 1 ..]

    block.call response.body total_size
