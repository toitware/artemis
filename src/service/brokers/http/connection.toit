// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import encoding.json
import encoding.base64
import http
import net
import reader show Reader
import system.storage
import certificate-roots
import ....shared.server-config show ServerConfigHttp

class HttpConnection_:
  client_/http.Client? := null
  config_/ServerConfigHttp
  network_/net.Interface
  static certificates-are-installed_/bool := false

  constructor .network_ .config_:
    if not certificates-are-installed_:
      certificates-are-installed_ = true
      certificate-roots.install-common-trusted-roots
    config_.install-root-certificates
    create-fresh-client_

  create-fresh-client_ -> none:
    if client_:
      client_.close
      client_ = null

    if config_.root-certificate-ders:
      client_ = http.Client.tls network_ --security-store=HttpSecurityStore_
    else:
      client_ = http.Client network_

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
    response/http.Response? := null

    MAX-ATTEMPTS ::= 3
    for i := 0; i < MAX-ATTEMPTS; i++:
      response = client_.post encoded
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
      create-fresh-client_

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
