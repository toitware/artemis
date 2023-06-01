// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.json
import encoding.base64
import http
import net
import reader show Reader

import ....shared.utils as utils

class HttpConnection_:
  client_/http.Client? := ?
  host_/string
  port_/int
  path_/string

  constructor network/net.Interface .host_ .port_ .path_:
    client_ = http.Client network

  is_closed -> bool:
    return client_ == null

  close:
    if not client_: return
    client_.close
    client_ = null

  send_request command/int data/Map -> any:
    send_request command data: | reader/Reader |
      return json.decode (utils.read_all reader)
    unreachable

  send_request command/int data/Map [block] -> none:
    encoded := #[command] + (json.encode data)
    response := client_.post encoded --host=host_ --port=port_ --path=path_
    body := response.body
    status := response.status_code

    if status == http.STATUS_IM_A_TEAPOT:
      decoded := json.decode (utils.read_all body)
      throw "Broker error: $decoded"

    try:
      if status != 200: throw "Not found ($status)"
      block.call body
    finally:
      catch: response.drain
