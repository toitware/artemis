// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import log
import net
import encoding.json

import ..artemis_server

import ....shared.broker_config
import ....shared.postgrest as supabase

class ArtemisServerServiceSupabase implements ArtemisServerService:
  broker_config_/BrokerConfigSupabase?

  hardware_id_/string

  constructor .broker_config_ --hardware_id/string:
    hardware_id_ = hardware_id

  check_in network/net.Interface logger/log.Logger:
    catch:
      headers := http.Headers
      anon := broker_config_.anon
      headers.add "apikey" anon
      headers.add "Authorization" "Bearer $anon"

      payload := """{
        "device": "$(json.escape_string hardware_id_)",
        "data": { "type": "ping" }
      }""".to_byte_array

      path := "/rest/v1/events"
      client := supabase.create_client network broker_config_
          --certificate_provider=: throw "UNSUPPORTED"

      // TODO(kasper): We need some timeout here.
      response := client.post payload
          --host=broker_config_.host
          --headers=headers
          --path=path
      body := response.body
      while data := body.read: null // DRAIN!
      return response.status_code == 201
    // Something went wrong.
    return false
