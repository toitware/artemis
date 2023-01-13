// Copyright (C) 2023 Toitware ApS. All rights reserved.

import monitor
import net

import supabase

import .supabase_local_server
import ..tools.http_servers.artemis_server show HttpArtemisServer DeviceEntry EventEntry
import ..tools.http_servers.artemis_server as http_servers
import artemis.shared.server_config show ServerConfig ServerConfigHttpToit ServerConfigSupabase
import .utils

class TestArtemisServer:
  server_config/ServerConfig
  backdoor/ArtemisServerBackdoor

  constructor .server_config .backdoor:

interface ArtemisServerBackdoor:
  /**
  Fetches the information of the device with the given $hardware_id.

  Returns a list of [hardware_id, fleet_id, alias]. If no alias exists, uses "" instead.
  */
  fetch_device_information --hardware_id/string -> List

  /** Whether there exists a '$type'-event for the given $hardware_id. */
  has_event --hardware_id/string --type/string -> bool

  /**
  Installs the given images.

  The $images parameter is a list of maps, each containing the
    following entries:
  - sdk_version: The SDK version of the image.
  - service_version: The service version of the image.
  - image: The image identifier.
  - content: The image content (a byte array).
  */
  install_service_images images/List

with_artemis_server --type/string [block]:
  if type == "supabase":
    server_config := get_supabase_config --sub_directory=SUPABASE_ARTEMIS
    service_key := get_supabase_service_key --sub_directory=SUPABASE_ARTEMIS
    backdoor := SupabaseBackdoor server_config service_key
    test_server := TestArtemisServer server_config backdoor
    block.call test_server
  else if type == "http":
    with_http_artemis_server block
  else:
    throw "Unknown Artemis server type: $type"

class ToitHttpBackdoor implements ArtemisServerBackdoor:
  server/HttpArtemisServer

  constructor .server:

  fetch_device_information --hardware_id/string -> List:
    entry/DeviceEntry := server.devices[hardware_id]
    return [
      entry.id,
      entry.organization_id,
      entry.alias,
    ]

  has_event --hardware_id/string --type/string -> bool:
    server.events.do: | entry/EventEntry |
      if entry.device_id == hardware_id and
          entry.data is Map and (entry.data.get "type") == type:
        return true
    return false

  install_service_images images/List -> none:
    image_binaries := {:}
    sdk_service_versions := []
    images.do: | entry/Map |
      sdk_service_versions.add {
        "sdk_version": entry["sdk_version"],
        "service_version": entry["service_version"],
        "image": entry["image"],
      }
      image_binaries[entry["image"]] = entry["content"]

    server.sdk_service_versions = sdk_service_versions
    server.image_binaries = image_binaries

with_http_artemis_server [block]:
  server := http_servers.HttpArtemisServer 0
  port_latch := monitor.Latch
  server_task := task:: server.start port_latch

  server_config := ServerConfigHttpToit "test-artemis-server"
      --host="localhost"
      --port=port_latch.get

  server.create_organization
      --id=TEST_ORGANIZATION_UUID
      --name=TEST_ORGANIZATION_NAME
      --admin_id=TEST_EXAMPLE_COM_UUID

  server.create_user --name=TEST_EXAMPLE_COM_NAME
      --email=TEST_EXAMPLE_COM_EMAIL
      --id=TEST_EXAMPLE_COM_UUID
  server.create_user --name=DEMO_EXAMPLE_COM_NAME
      --email=DEMO_EXAMPLE_COM_EMAIL
      --id=DEMO_EXAMPLE_COM_UUID


  backdoor/ToitHttpBackdoor := ToitHttpBackdoor server

  test_server := TestArtemisServer server_config backdoor
  try:
    block.call test_server
  finally:
    server.close
    server_task.cancel

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
          (it["data"].get "type") == type:
        return true
    return false

  install_service_images images/List -> none:
    with_backdoor_client_: | client/supabase.Client |
      // Clear the sdks, service-versions and images table.
      // Deletes require a where clause, so we use a filter that matches all IDs.
      client.rest.delete "sdks" --filters=["id=gte.0"]
      client.rest.delete "artemis_services" --filters=["id=gte.0"]
      client.rest.delete "service_images" --filters=["id=gte.0"]

      sdk_versions := {:}
      service_versions := {:}

      images.do: | entry/Map |
        sdk_version := entry["sdk_version"]
        service_version := entry["service_version"]
        image := entry["image"]
        content := entry["content"]

        sdk_id := sdk_versions.get sdk_version --init=:
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
