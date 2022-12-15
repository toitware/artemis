// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import net
import net.x509
import http.status_codes
import encoding.json

interface ServerConfig:
  host -> string
  anon -> string
  certificate_name -> string?
  certificate_text -> string?

create_client -> http.Client
    network/net.Interface
    server_config/ServerConfig
    [--certificate_provider]:
  root_certificate_text := server_config.certificate_text
  if not root_certificate_text and server_config.certificate_name:
    root_certificate_text = certificate_provider.call server_config.certificate_name
  if root_certificate_text:
    certificate := x509.Certificate.parse root_certificate_text
    return http.Client.tls network --root_certificates=[certificate]
  else:
    return http.Client network

create_headers server_config/ServerConfig -> http.Headers:
  anon := server_config.anon
  headers := http.Headers
  headers.add "apikey" anon
  // By default the bearer is the anon-key. This can be overridden.
  headers.add "Authorization" "Bearer $anon"
  return headers

query_ client/http.Client host/string headers/http.Headers table/string filters/List=[] -> List?:
  filter := filters.is_empty ? "" : "?$(filters.join "&")"
  path := "/rest/v1/$table$filter"
  response := client.get host --headers=headers "$path"
  body := response.body
  result := null
  if response.status_code == status_codes.STATUS_OK:
    result = json.decode_stream body
  while data := body.read: null // DRAIN!
  return result

/**
A client for the Supabase API.

Supabase provides several different APIs under one umbrella.

A frontend ('Kong'), takes the requests and forwards them to the correct
  backend.
Each supported backend is available through a different getter.
For example, the Postgres backend is available through the $rest getter, and
  the storage backend is available through $storage.
*/
class Client:
  http_client_/http.Client? := null

  /**
  The used network interface.
  This field is only set, if the $close function should close the network_.
  */
  network_/net.Interface? := null

  /**
  The host of the Supabase project.
  */
  host_/string

  /**
  The anonymous key of the Supabase project.

  This key is used as api key.
  If the user is not authenticated the client uses this key as the bearer.
  */
  anon_/string

  rest_/PostgRest? := null
  storage_/Storage? := null

  constructor network/net.Interface?=null --host/string --anon/string:
    host_ = host
    anon_ = anon

    if not network:
      network = network_ = net.open

    http_client_ = http.Client network

  constructor.tls network/net.Interface?=null --host/string --anon/string --root_certificates/List:
    host_ = host
    anon_ = anon

    if not network:
      network = network_ = net.open

    http_client_ = http.Client.tls network --root_certificates=root_certificates

  constructor network/net.Interface?=null --server_config/ServerConfig [--certificate_provider]:
    root_certificate_text := server_config.certificate_text
    if not root_certificate_text and server_config.certificate_name:
      root_certificate_text = certificate_provider.call server_config.certificate_name
    if root_certificate_text:
      certificate := x509.Certificate.parse root_certificate_text
      return Client.tls network --host=server_config.host --anon=server_config.anon
          --root_certificates=[certificate]
    else:
      return Client network --host=server_config.host --anon=server_config.anon

  close -> none:
    // TODO(florian): call close on the http client (when that's possible).
    http_client_ = null
    if network_:
      network_.close
      network_ = null

  is_closed -> bool:
    return http_client_ == null

  rest -> PostgRest:
    if not rest_: rest_ = PostgRest this
    return rest_

  storage -> Storage:
    if not storage_: storage_ = Storage this
    return storage_

  // TODO(florian): remove this functionality, and create a more flexible 'query'
  // function on the client instead.
  create_headers_ -> http.Headers:
    headers := http.Headers
    headers.add "apikey" anon_
    // By default the bearer is the anon-key. This can be overridden.
    headers.add "Authorization" "Bearer $anon_"
    return headers


class PostgRest:
  client_/Client

  constructor .client_:

  query table/string filters/List -> List?:
    headers := client_.create_headers_
    return query_ client_.http_client_ client_.host_ headers table filters

  update_entry table/string --upsert/bool payload/ByteArray:
    headers := client_.create_headers_
    if upsert: headers.add "Prefer" "resolution=merge-duplicates"
    response := client_.http_client_.post payload
        --host=client_.host_
        --headers=headers
        --path="/rest/v1/$table"
    // 201 is changed one entry.
    body := response.body
    while data := body.read: null // DRAIN!
    if response.status_code != 201: throw "UGH ($response.status_code)"

class Storage:
  client_/Client

  constructor .client_:

  upload_resource --path/string --content/ByteArray:
    headers := client_.create_headers_
    headers.add "Content-Type" "application/octet-stream"
    headers.add "x-upsert" "true"
    response := client_.http_client_.post content
        --host=client_.host_
        --headers=headers
        --path="/storage/v1/object/$path"
    // 200 is accepted!
    body := response.body
    while data := body.read: null // DRAIN!
    if response.status_code != 200: throw "UGH ($response.status_code)"

  download_resource --path/string [block] -> none:
    headers := client_.create_headers_
    response := client_.http_client_.get client_.host_ "/storage/v1/object/$path"
        --headers=headers
    body := response.body
    try:
      // 200 is accepted!
      if response.status_code != 200: throw "UGH ($response.status_code)"
      block.call body
    finally:
      while data := body.read: null // DRAIN!
