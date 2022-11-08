// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import http

import .base
import ....shared.postgrest as postgrest
import ....shared.postgrest show create_headers create_client
import ....shared.broker_config

export create_headers create_client

create_broker_cli_supabase broker_config/SupabaseBrokerConfig -> BrokerCliPostgrest:
  network := net.open
  http_client := postgrest.create_client network broker_config
  postgrest_client := postgrest.SupabaseClient http_client broker_config
  id := "supabase/$broker_config.host"
  return BrokerCliPostgrest postgrest_client network --id=id
