// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.json
import encoding.base64
import http
import net
import net.x509
import reader show Reader
import system.storage
import ....shared.server_config show ServerConfigHttp

class HttpConnection_:
  client_/http.Client? := ?
  config_/ServerConfigHttp

  constructor network/net.Interface .config_:
    if config_.root_certificate_ders:
      root_certificates := config_.root_certificate_ders.map:
        x509.Certificate.parse it
      client_ = http.Client.tls network
          --root_certificates=root_certificates
          --security_store=HttpSecurityStore_
    else:
      client_ = http.Client network

  is_closed -> bool:
    return client_ == null

  close:
    if not client_: return
    client_.close
    client_ = null

  send_request command/int data/Map -> any:
    send_request command data: | reader/Reader |
      return json.decode_stream reader
    unreachable

  send_request command/int data/Map [block] -> none:
    encoded := #[command] + (json.encode data)
    request_headers/http.Headers? := null
    if config_.device_headers:
      request_headers = http.Headers
      config_.device_headers.do: | key value |
        request_headers.add key value

    response := client_.post encoded
        --host=config_.host
        --port=config_.port
        --path=config_.path
        --headers=request_headers
    body := response.body
    status := response.status_code

    if status == http.STATUS_IM_A_TEAPOT:
      decoded := json.decode_stream body
      throw "Broker error: $decoded"

    try:
      if status != 200: throw "Not found ($status)"
      block.call body
    finally:
      catch: response.drain

class HttpSecurityStore_ extends http.SecurityStore:
  // We store the cached session data in RTC memory. This means that
  // it survives deep sleeps, but that any loss of power or firmware
  // update will clear it.
  static bucket/storage.Bucket ::= storage.Bucket.open --ram "toit.io/artemis/tls"

  store_session_data host/string port/int data/ByteArray -> none:
    bucket[key_ host port] = data

  delete_session_data host/string port/int -> none:
    bucket.remove (key_ host port)

  retrieve_session_data host/string port/int -> ByteArray?:
    return bucket.get (key_ host port)

  key_ host/string port/int -> string:
    return "$host:$port"
