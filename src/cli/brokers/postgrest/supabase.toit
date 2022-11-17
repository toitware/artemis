// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import http
import certificate_roots

import .base
import ....shared.postgrest as postgrest
import ....shared.postgrest show create_headers create_client
import ....shared.server_config

export create_headers create_client

create_broker_cli_supabase server_config/ServerConfigSupabase -> BrokerCliPostgrest:
  network := net.open
  http_client := postgrest.create_client network server_config
      --certificate_provider=: certificate_roots.MAP[it]
  postgrest_client := postgrest.SupabaseClient http_client server_config
  id := "supabase/$server_config.host"
  return BrokerCliPostgrest postgrest_client network --id=id
