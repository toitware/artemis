// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.json
import encoding.base64
import http
import net
import net.x509
import reader show Reader
import system.storage
import ....shared.server-config show ServerConfigHttp

class HttpConnection_:
  client_/http.Client? := ?
  config_/ServerConfigHttp
  network_/net.Interface

  constructor .network_ .config_:
    client_ = create-client_ config_ network_

  static create-client_ config/ServerConfigHttp network/net.Interface -> http.Client:
    if config.root-certificate-ders:
      root-certificates := config.root-certificate-ders.map:
        x509.Certificate.parse it
      return http.Client.tls network
          --root-certificates=root-certificates
          --security-store=HttpSecurityStore_
    else:
      return http.Client network

  is-closed -> bool:
    return client_ == null

  close:
    if not client_: return
    client_.close
    client_ = null

  send-request command/int data/Map -> any:
    send-request command data: | reader/Reader |
      return json.decode-stream reader
    unreachable

  send-request command/int data/Map --expected-status/int?=null [block] -> none:
    encoded := #[command] + (json.encode data)
    request-headers/http.Headers? := null
    if config_.device-headers:
      request-headers = http.Headers
      config_.device-headers.do: | key value |
        request-headers.add key value

    body/Reader? := null
    status/int := -1

    MAX-ATTEMPTS ::= 3
    for i := 0; i < MAX-ATTEMPTS; i++:
      response := client_.post encoded
          --host=config_.host
          --port=config_.port
          --path=config_.path
          --headers=request-headers
      body = response.body
      status = response.status-code

      if status != http.STATUS-BAD-GATEWAY or i == MAX-ATTEMPTS - 1:
        break

      // Cloudflare frequently returns with a 502.
      // Close the client and try again.
      client_.close
      client_ = null
      client_ = create-client_ config_ network_

    if status == http.STATUS-IM-A-TEAPOT:
      decoded := json.decode-stream body
      throw "Broker error: $decoded"

    try:
      if expected-status and expected-status != status:
        throw "Unexpected status: $status"
      if status == http.STATUS-NOT-FOUND: throw "Not found"
      if not 200 <= status < 300: throw "Unexpected status: $status"
      block.call body
    finally:
      catch: response.drain

class HttpSecurityStore_ extends http.SecurityStore:
  // We store the cached session data in RTC memory. This means that
  // it survives deep sleeps, but that any loss of power or firmware
  // update will clear it.
  static bucket ::= storage.Bucket.open --ram "toit.io/artemis/tls"

  store-session-data host/string port/int data/ByteArray -> none:
    bucket[key_ host port] = data

  delete-session-data host/string port/int -> none:
    bucket.remove (key_ host port)

  retrieve-session-data host/string port/int -> ByteArray?:
    return bucket.get (key_ host port)

  key_ host/string port/int -> string:
    return "$host:$port"
