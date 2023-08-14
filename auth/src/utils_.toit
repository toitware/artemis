// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import encoding.url
import http
import net

with-http-client network/net.Client?=null --root-certificates/List [block]:
  network-needs-close := false
  if not network:
    network = net.open
    network-needs-close = true

  client/http.Client? := null
  try:
    if root-certificates and not root-certificates.is-empty:
      client = http.Client.tls network --root-certificates=root-certificates
    else:
      client = http.Client network

    block.call client
  finally:
    if client: client.close
    if network-needs-close: network.close

build-url-encoded-query-parameters parameters/Map -> string:
  query-parameters := []

  add := : | key value |
    query-parameters.add "$(url.encode key)=$(url.encode value)"

  parameters.do: | key value |
    if value is List:
      value.do: | item |
        add.call key item
    else:
      add.call key value
  return query-parameters.join "&"
