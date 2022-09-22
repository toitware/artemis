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

  post payload/ByteArray --path/string --headers/http.Headers -> http.Response:
    headers = headers.copy
    supabase_add_auth_headers headers
    return client_.post payload
        --host=SUPABASE_HOST
        --headers=headers
        --path=path

create_supabase_mediator -> Mediator:
  network := net.open
  http_client := supabase_create_client network
  postgrest_client := SupabaseClient http_client
  return MediatorPostgrest postgrest_client network
