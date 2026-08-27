// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.json
import encoding.base64
import http
import net
import reader show Reader
import system.storage
import ....shared.server-config show ServerConfigHttp ServerConfigHttpTemplates

class HttpConnection_:
  client_/http.Client? := null
  config_/ServerConfigHttp
  network_/net.Interface

  constructor .network_ .config_:
    config_.install-root-certificates
    create-fresh-client_

  create-fresh-client_ -> none:
    if client_:
      client_.close
      client_ = null

    if config_.use-tls or config_.root-certificate-ders:
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
      if i != 0:
        // We are retrying. Create a fresh client.
        create-fresh-client_

      response = client_.post encoded
          --host=config_.host
          --port=config_.port
          --path=config_.path
          --headers=request-headers
      body = response.body
      status = response.status-code

      // Cloudflare frequently rejects our requests with a 502, 520 or 546, which
      // we retry a few times to see if it was a temporary issue.
      // If it's not one of these, we are done.
      if status != http.STATUS-BAD-GATEWAY and status != 520 and status != 546:
        break

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

class HttpTemplateConnection_:
  client_/http.Client? := null
  config_/ServerConfigHttpTemplates
  network_/net.Interface

  constructor .network_ .config_:
    config_.install-root-certificates
    create-fresh-client_

  create-fresh-client_ -> none:
    if client_:
      client_.close
      client_ = null
    client_ = http.Client network_ --security-store=HttpSecurityStore_

  close -> none:
    if not client_: return
    client_.close
    client_ = null

  send-json method/string url/string data/any=null -> any:
    encoded/ByteArray? := data == null ? null : json.encode data
    response := send-request_ method url encoded
        --content-type=(encoded ? "application/json" : null)
    try:
      check-status_ response
      return json.decode-stream response.body
    finally:
      catch: response.drain

  download url/string --offset/int=0 [block] -> none:
    headers/http.Headers? := null
    if offset != 0:
      headers = request-headers_ or http.Headers
      headers.set "Range" "bytes=$offset-"
    response := send-request_ http.GET url null --headers=headers
    try:
      check-status_ response
      if offset != 0:
        if response.status-code == http.STATUS-OK:
          // The server ignored the range. Discard the prefix locally.
          response.body.skip offset
        else if response.status-code != http.STATUS-PARTIAL-CONTENT:
          throw "Unexpected status: $response.status-code"
      block.call response.body
    finally:
      catch: response.drain

  send-request_ method/string url/string data/ByteArray?
      --headers/http.Headers?=null
      --content-type/string?=null
      -> http.Response:
    MAX-ATTEMPTS ::= 3
    MAX-ATTEMPTS.repeat: | attempt/int |
      request-headers := headers or request-headers_
      response := client_.request method data
          --uri=url
          --headers=request-headers
          --content-type=content-type
          --retry-on-connection-close
      status := response.status-code
      retry := status == http.STATUS-BAD-GATEWAY or status == 520 or status == 546
      if retry and attempt != MAX-ATTEMPTS - 1:
        catch: response.drain
        create-fresh-client_
        continue.repeat
      return response
    unreachable

  request-headers_ -> http.Headers?:
    if not config_.headers: return null
    result := http.Headers
    config_.headers.do: | key value |
      result.add key value
    return result

  check-status_ response/http.Response -> none:
    if response.status-code == http.STATUS-NOT-FOUND: throw "Not found"
    if not http.is-success-status-code response.status-code:
      throw "Unexpected status: $response.status-code"
