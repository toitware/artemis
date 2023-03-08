// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import log
import net
import encoding.json
import supabase

import ..artemis_server

import ....shared.server_config

class ArtemisServerServiceSupabase implements ArtemisServerService:
  server_config_/ServerConfigSupabase

  hardware_id_/string

  constructor .server_config_ --hardware_id/string:
    hardware_id_ = hardware_id

  check_in network/net.Interface logger/log.Logger -> none:
    client := supabase.Client network --server_config=server_config_
        --certificate_provider=: throw "UNSUPPORTED"

    client.rest.insert "events" --no-return_inserted {
      "device_id": hardware_id_,
      "data": { "type": "ping" }
    }
