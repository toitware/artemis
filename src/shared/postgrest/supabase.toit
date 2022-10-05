// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import net
import net.x509
import http
import http.status_codes
import encoding.json

import ..device
import .base

create_mediator_cli_supabase broker/Map -> MediatorCliPostgrest:
  network := net.open
  http_client := create_client network broker
  postgrest_client := SupabaseClient http_client broker
  return MediatorCliPostgrest postgrest_client network

create_client network/net.Interface broker/Map -> http.Client:
  certificate_text := broker["supabase"]["certificate"]
  certificate := x509.Certificate.parse certificate_text
  return http.Client.tls network --root_certificates=[certificate]

create_headers broker/Map -> http.Headers:
  anon := broker["supabase"]["anon"]
  headers := http.Headers
  headers.add "apikey" anon
  headers.add "Authorization" "Bearer $anon"
  return headers

query_ client/http.Client host/string headers/http.Headers table/string filters/List=[] -> List?:
  filter := filters.is_empty ? "" : "?$(filters.join "&")"
  path := "/rest/v1/$table$filter"
  response := client.get host --headers=headers "$path"
  if response.status_code != status_codes.STATUS_OK: return null
  return json.decode_stream response.body

class SupabaseClient implements PostgrestClient:
  client_/http.Client? := null
  broker_/Map
  host_/string

  constructor .client_ .broker_:
    host_ = broker_["supabase"]["host"]

  close -> none:
    client_ = null

  is_closed -> bool:
    return client_ == null

  query table/string filters/List -> List?:
    headers := create_headers broker_
    return query_ client_ host_ headers table filters

  update_entry table/string --id/int? payload/ByteArray:
    headers := create_headers broker_

    upsert := ""
    if id:
      headers.add "Prefer" "resolution=merge-duplicates"
      upsert = "?id=eq.$id"

    response := client_.post payload
        --host=host_
        --headers=headers
        --path="/rest/v1/$table$upsert"
    // 201 is changed one entry.
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
    if response.status_code != 200: throw "UGH ($response.status_code)"
