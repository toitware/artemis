// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import net
import http

import ..device

HOST ::= "uelhwhbsyumuqhbukich.supabase.co"
PORT ::= 80

ANON_ ::= "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVlbGh3aGJzeXVtdXFoYnVraWNoIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NjM1OTU0NDYsImV4cCI6MTk3OTE3MTQ0Nn0.X6yvaUJDoN0Zk1xjYy_Ap-w6NhCc5BtyWnh5zGdoPFo"

class DevicePostgrest implements Device:
  name/string
  constructor .name:

create_client network/net.Interface -> http.Client:
  return http.Client.tls network
      --root_certificates=[certificate_roots.BALTIMORE_CYBERTRUST_ROOT]

create_headers -> http.Headers:
  headers := http.Headers
  headers.add "apikey" ANON_
  headers.add "Authorization" "Bearer $ANON_"
  return headers
