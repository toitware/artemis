// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import monitor
import http
import encoding.json

import .base
import ..mediator
import ...shared.device
import ...shared.postgrest.supabase

create_supabase_mediator -> Mediator:
  network := net.open
  client := supabase_create_client network
  return MediatorPostgrest client network
