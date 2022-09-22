// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import monitor
import http
import encoding.json

import .base
import ..mediator
import ...shared.device
import ...shared.postgrest.supabase

class SupabaseClient implements PostgrestClient:
  client_/http.Client? := null

  constructor .client_:

  close -> none:
    client_ = null

  is_closed -> bool:
    return client_ == null

  query table/string filters/List -> List?:
    headers := http.Headers
    supabase_add_auth_headers headers
    return supabase_query client_ headers table filters

  update_entry table/string --id/int? payload/ByteArray:
    headers := http.Headers
    supabase_add_auth_headers headers

    upsert := ""
    if id:
      headers.add "Prefer" "resolution=merge-duplicates"
      upsert = "?id=eq.$id"

    response := client_.post payload
        --host=SUPABASE_HOST
        --headers=headers
        --path="/rest/v1/$table$upsert"
    // 201 is changed one entry.
    if response.status_code != 201: throw "UGH ($response.status_code)"

  upload_resource --path/string --content/ByteArray:
    headers := http.Headers
    supabase_add_auth_headers headers
    headers.add "Content-Type" "application/octet-stream"
    headers.add "x-upsert" "true"
    response := client_.post content
        --host=SUPABASE_HOST
        --headers=headers
        --path="/storage/v1/object/$path"
    // 200 is accepted!
    if response.status_code != 200: throw "UGH ($response.status_code)"

create_supabase_mediator -> Mediator:
  network := net.open
  http_client := supabase_create_client network
  postgrest_client := SupabaseClient http_client
  return MediatorPostgrest postgrest_client network
