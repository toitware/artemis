// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import supabase

import .supabase_local_server
import .artemis_server_test_base
import .utils
import artemis.shared.server_config show ServerConfigSupabase
import artemis.cli.config as cli
import artemis.cli.server_config as cli_server_config
import artemis.cli.auth as cli_auth

class SupabaseBackdoor implements ArtemisServerBackdoor:
  server_config_/ServerConfigSupabase

  constructor .server_config_:

  fetch_device_information --hardware_id/string -> List:
    entry := query_ "devices" [
      "id=eq.$hardware_id",
    ]
    return [
      entry[0]["id"],
      entry[0]["organization_id"],
      entry[0]["alias"],
    ]

  has_event --hardware_id/string --type/string -> bool:
    // For simplicity just run through all entries.
    // In the test-setup we should not have that many.
    entries := query_ "events" [
      "device_id=eq.$hardware_id",
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
    supabase_client/supabase.Client? := null
    try:
      supabase_client = supabase.Client
          --server_config=server_config_
          --certificate_provider=: unreachable
      // We might need to use the service_role key at some point, to
      // have more access. For now we have access to all the data we need.
      supabase_client.auth.sign_in
          --email=TEST_EXAMPLE_COM_EMAIL
          --password=TEST_EXAMPLE_COM_PASSWORD

      return supabase_client.rest.select table --filters=filters
    finally:
      if supabase_client: supabase_client.close
      network.close

main:
  server_config := get_supabase_config --sub_directory=SUPABASE_ARTEMIS
  backdoor := SupabaseBackdoor server_config
  run_test server_config backdoor --authenticate=: | config |
    cli_auth.sign_in server_config config --email=TEST_EXAMPLE_COM_EMAIL --password=TEST_EXAMPLE_COM_PASSWORD

