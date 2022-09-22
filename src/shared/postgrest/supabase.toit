// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import net
import http
import http.status_codes
import encoding.json

import ..device

SUPABASE_HOST ::= "uelhwhbsyumuqhbukich.supabase.co"
ANON_ ::= "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVlbGh3aGJzeXVtdXFoYnVraWNoIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NjM1OTU0NDYsImV4cCI6MTk3OTE3MTQ0Nn0.X6yvaUJDoN0Zk1xjYy_Ap-w6NhCc5BtyWnh5zGdoPFo"

class DevicePostgrest implements Device:
  name/string
  constructor .name:

supabase_create_client network/net.Interface -> http.Client:
  return http.Client.tls network
      --root_certificates=[certificate_roots.BALTIMORE_CYBERTRUST_ROOT]

supabase_add_auth_headers headers/http.Headers:
  headers.add "apikey" ANON_
  headers.add "Authorization" "Bearer $ANON_"

supabase_create_headers -> http.Headers:
  headers := http.Headers
  supabase_add_auth_headers headers
  return headers

supabase_query client/http.Client headers/http.Headers table/string filters/List=[] -> List?:
  filter := filters.is_empty ? "" : "?$(filters.join "&")"
  path := "/rest/v1/$table$filter"
  response := client.get SUPABASE_HOST --headers=headers "$path"
  if response.status_code != status_codes.STATUS_OK: return null
  return json.decode_stream response.body
