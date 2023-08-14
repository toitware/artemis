// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import log
import net
import encoding.json
import supabase
import uuid

import ..artemis-server

import ....shared.server-config

class ArtemisServerServiceSupabase implements ArtemisServerService:
  server-config_/ServerConfigSupabase

  hardware-id_/uuid.Uuid

  constructor .server-config_ --hardware-id/uuid.Uuid:
    hardware-id_ = hardware-id

  check-in network/net.Interface logger/log.Logger -> none:
    client := supabase.Client network --server-config=server-config_
        --certificate-provider=: throw "UNSUPPORTED"

    client.rest.insert "events" --no-return-inserted {
      "device_id": "$hardware-id_",
      "data": { "type": "ping" }
    }
