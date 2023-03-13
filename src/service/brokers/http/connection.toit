// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import encoding.base64
import http
import net
import reader show SizedReader

STATUS_IM_A_TEAPOT ::= 418

class HttpConnection_:
  network_/net.Interface
  host_/string
  port_/int

  constructor .network_ .host_ .port_:

  send_request command/string data/Map -> any:
    payload := {
      "command": command,
      "data": data,
    }

    send_request_ payload: | reader/SizedReader |
      encoded_response := read_response_ reader
      return ubjson.decode encoded_response
    unreachable

  send_binary_request command/string data/Map [block] -> none:
    payload :=  {
      "command": command,
      "data": data,
      "binary": true,
    }
    send_request_ payload block

  send_request_ payload/Map [block] -> none:
    client := http.Client network_
    encoded := ubjson.encode payload
    response := client.post encoded --host=host_ --port=port_ --path="/"

    body := response.body as SizedReader
    status := response.status_code

    if status == STATUS_IM_A_TEAPOT:
      encoded_response := read_response_ body
      decoded := ubjson.decode encoded_response
      throw "Broker error: $decoded"

    try:
      if status != 200: throw "Not found ($status)"
      block.call body
    finally:
      while data := body.read: null // DRAIN!

  read_response_ reader/SizedReader -> ByteArray:
    result := ByteArray reader.size
    offset := 0
    while chunk := reader.read:
      result.replace offset chunk
      offset += chunk.size
    return result
