// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import http

import .base
import ....shared.postgrest as postgrest
import ....shared.postgrest show create_headers create_client

export create_headers create_client

create_broker_cli_supabase broker/Map -> BrokerCliPostgrest:
  network := net.open
  http_client := postgrest.create_client network broker
  postgrest_client := postgrest.SupabaseClient http_client broker
  id := "supabase/$broker["host"]"
  return BrokerCliPostgrest postgrest_client network --id=id
