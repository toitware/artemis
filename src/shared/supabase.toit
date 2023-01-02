// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import net
import net.x509
import http.status_codes
import encoding.json
import .server_config

/**
Supabase functionality.

This library contains functionality and constants that are shared between
  the CLI and the service.

Ideally, there is (or should be) a clear separation between the parts that
  are here because both sides agree on them, and the parts that are
  just generic and could live in their own package.
*/

create_client -> http.Client
    network/net.Interface
    server_config/ServerConfigSupabase
    [--certificate_provider]:
  root_certificate_text := server_config.certificate_text
  if not root_certificate_text and server_config.certificate_name:
    root_certificate_text = certificate_provider.call server_config.certificate_name
  if root_certificate_text:
    certificate := x509.Certificate.parse root_certificate_text
    return http.Client.tls network --root_certificates=[certificate]
  else:
    return http.Client network

create_headers server_config/ServerConfigSupabase -> http.Headers:
  anon := server_config.anon
  headers := http.Headers
  headers.add "apikey" anon
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

class SupabaseClient:
  client_/http.Client? := null
  broker_/ServerConfigSupabase
  host_/string

  constructor .client_ .broker_:
    host_ = broker_.host

  close -> none:
    client_ = null

  is_closed -> bool:
    return client_ == null

  query table/string filters/List -> List?:
    headers := create_headers broker_
    return query_ client_ host_ headers table filters

  update_entry table/string --upsert/bool payload/ByteArray:
    headers := create_headers broker_
    if upsert: headers.add "Prefer" "resolution=merge-duplicates"
    response := client_.post payload
        --host=host_
        --headers=headers
        --path="/rest/v1/$table"
    // 201 is changed one entry.
    body := response.body
    while data := body.read: null // DRAIN!
    if response.status_code != 201: throw "UGH ($response.status_code)"

  upload_resource --path/string --content/ByteArray:
    headers := create_headers broker_
    headers.add "Content-Type" "application/octet-stream"
    headers.add "x-upsert" "true"
    response := client_.post content
        --host=host_
        --headers=headers
        --path="/storage/v1/object/$path"
    // 200 is accepted!
    body := response.body
    while data := body.read: null // DRAIN!
    if response.status_code != 200: throw "UGH ($response.status_code)"

  download_resource --path/string [block] -> none:
    headers := create_headers broker_
    response := client_.get host_ "/storage/v1/object/$path"
        --headers=headers
    body := response.body
    try:
      // 200 is accepted!
      if response.status_code != 200: throw "UGH ($response.status_code)"
      block.call body
    finally:
      while data := body.read: null // DRAIN!
