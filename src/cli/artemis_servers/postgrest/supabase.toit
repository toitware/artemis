// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import http
import net
import encoding.json

import ..artemis_server

import ....shared.server_config
import ....shared.postgrest as supabase

class ArtemisServerCliSupabase implements ArtemisServerCli:
  client_/http.Client
  server_config_/ServerConfigSupabase

  constructor network/net.Interface .server_config_/ServerConfigSupabase:
    client_ = supabase.create_client network server_config_
        --certificate_provider=: certificate_roots.MAP[it]

  is_closed -> bool:
    // TODO(florian): we need a newer http client to be able to
    // ask whether it's closed.
    return false

  close -> none:
    // TODO(florian): we need a newer http client to be able to close it.

  create_device_in_fleet --fleet_id/string --device_id/string -> string:
    map := {
      "fleet": fleet_id,
    }
    if device_id != "": map["alias"] = device_id
    payload := json.encode map

    headers := supabase.create_headers server_config_
    headers.add "Prefer" "return=representation"
    table := "devices"
    response := client_.post payload
        --host=server_config_.host
        --headers=headers
        --path="/rest/v1/$table"

    if response.status_code != 201:
      throw "Unable to create device identity"
    decoded_row := (json.decode_stream response.body).first
    return decoded_row["id"]

  notify_created --hardware_id/string -> none:
    map := {
      "device": hardware_id,
      "data": { "type": "created" }
    }
    payload := json.encode map

    headers := supabase.create_headers server_config_
    table := "events"
    response := client_.post payload
        --host=server_config_.host
        --headers=headers
        --path="/rest/v1/$table"
    if response.status_code != 201:
      throw "Unable to insert 'created' event."
