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
  service_key_/string

  constructor .server_config_ .service_key_:

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

  install_service_images images/List -> none:
    with_backdoor_client_: | client/supabase.Client |
      // Clear the sdks, service-versions and images table.
      client.rest.delete "sdks" --filters=[]
      client.rest.delete "artemis_services" --filters=[]
      client.rest.delete "service_images" --filters=[]

      sdk_versions := {:}
      service_versions := {:}

      images.do: | entry/Map |
        sdk_version := entry["sdk_version"]
        service_version := entry["service_version"]
        image := entry["image"]
        content := entry["content"]

        sdk_id := sdk_versions.get sdk_version --init=:
          print "adding sdk version $sdk_version"
          new_entry := client.rest.insert "sdks" {
            "version": sdk_version,
          }
          new_entry["id"]
        service_id := service_versions.get service_version --init=:
          new_entry := client.rest.insert "artemis_services" {
            "version": service_version,
          }
          new_entry["id"]

        client.rest.insert "service_images" {
          "sdk_id": sdk_id,
          "service_id": service_id,
          "image": image,
        }

        client.storage.upload --path="service-images/$image" --content=content

  query_ table/string filters/List=[] -> List?:
    with_backdoor_client_: | client/supabase.Client |
      return client.rest.select table --filters=filters
    unreachable

  with_backdoor_client_ [block]:
    network := net.open
    supabase_client/supabase.Client? := null
    try:
      supabase_client = supabase.Client
          --host=server_config_.host
          --anon=service_key_
      block.call supabase_client
    finally:
      if supabase_client: supabase_client.close
      network.close

main:
  server_config := get_supabase_config --sub_directory=SUPABASE_ARTEMIS
  service_key := get_supabase_service_key --sub_directory=SUPABASE_ARTEMIS
  backdoor := SupabaseBackdoor server_config service_key
  run_test server_config backdoor --authenticate=: | config |
    cli_auth.sign_in server_config config --email=TEST_EXAMPLE_COM_EMAIL --password=TEST_EXAMPLE_COM_PASSWORD

