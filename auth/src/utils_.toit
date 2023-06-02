// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import encoding.url
import http
import net

with_http_client network/net.Client?=null --root_certificates/List [block]:
  network_needs_close := false
  if not network:
    network = net.open
    network_needs_close = true

  client/http.Client? := null
  try:
    if root_certificates and not root_certificates.is_empty:
      client = http.Client.tls network --root_certificates=root_certificates
    else:
      client = http.Client network

    block.call client
  finally:
    if client: client.close
    if network_needs_close: network.close

build_url_encoded_query_parameters parameters/Map -> string:
  query_parameters := []

  add := : | key value |
    query_parameters.add "$(url.encode key)=$(url.encode value)"

  parameters.do: | key value |
    if value is List:
      value.do: | item |
        add.call key item
    else:
      add.call key value
  return query_parameters.join "&"
