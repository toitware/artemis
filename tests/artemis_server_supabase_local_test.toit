// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net

import .supabase_local_server
import .artemis_server_test_base
import artemis.shared.server_config show ServerConfigSupabase
import artemis.shared.postgrest

class SupabaseBackdoor implements ArtemisServerBackdoor:
  server_config_/ServerConfigSupabase

  constructor .server_config_:

  fetch_device_information --hardware_id/string -> List:
    entry := query_ "devices" [
      "id=eq.$hardware_id",
    ]
    return [
      entry[0]["id"],
      entry[0]["fleet"],
      entry[0]["alias"],
    ]

  has_event --hardware_id/string --type/string -> bool:
    // For simplicity just run through all entries.
    // In the test-setup we should have that many.
    entries := query_ "events" [
      "device=eq.$hardware_id",
    ]
    if not entries: return false
    entries.do:
      if it["data"] is Map and
          it["data"].contains "type" and
          it["data"]["type"] == type:
        return true
    return false

  query_ table/string filters/List=[] -> List?:
    network := net.open
    supabase_client/postgrest.SupabaseClient? := null
    try:
      http_client := postgrest.create_client network server_config_ --certificate_provider=:unreachable
      supabase_client = postgrest.SupabaseClient http_client server_config_
      return supabase_client.query table filters
    finally:
      if supabase_client: supabase_client.close
      network.close

main:
  server_config := get_supabase_config --sub_directory="supabase_toitware"
  backdoor := SupabaseBackdoor server_config
  run_test server_config backdoor
