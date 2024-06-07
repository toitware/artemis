// Copyright (C) 2023 Toitware ApS. All rights reserved.

import monitor
import net
import supabase
import supabase.filter show equals greater-than-or-equal
import system
import uuid

import .supabase-local-server
import ..tools.http-servers.artemis-server show HttpArtemisServer DeviceEntry EventEntry
import ..tools.http-servers.artemis-server as http-servers
import ..tools.lan-ip.lan-ip
import artemis.shared.server-config show ServerConfig ServerConfigHttp ServerConfigSupabase
import .utils

class TestArtemisServer:
  server-config/ServerConfig
  backdoor/ArtemisServerBackdoor

  constructor .server-config .backdoor:

interface ArtemisServerBackdoor:
  /**
  Fetches the information of the device with the given $hardware-id.

  Returns a list of [hardware_id, fleet_id, alias]. If no alias exists, uses "" instead.
  */
  fetch-device-information --hardware-id/uuid.Uuid -> List

  /** Whether there exists a '$type'-event for the given $hardware-id. */
  has-event --hardware-id/uuid.Uuid --type/string -> bool

  /**
  Installs the given images.

  The $images parameter is a list of maps, each containing the
    following entries:
  - sdk_version: The SDK version of the image.
  - service_version: The service version of the image.
  - image: The image identifier.
  - content: The image content (a byte array).
  */
  install-service-images images/List

  /**
  Creates a new device in the given $organization-id.

  Returns a map with the device ID ("id"), and alias ID ("alias") of
    the created device.
  */
  create-device --organization-id/uuid.Uuid -> Map

  /**
  Removes the device with the given $device-id.
  */
  remove-device device-id/uuid.Uuid -> none

with-artemis-server
    --type/string
    --args/List
    [block]:
  if type == "supabase":
    // Make sure we are running with the correct resource lock.
    check-resource-lock "artemis_server" --args=args
    server-config := get-supabase-config --sub-directory=SUPABASE-ARTEMIS
    service-key := get-supabase-service-key --sub-directory=SUPABASE-ARTEMIS
    backdoor := SupabaseBackdoor server-config service-key
    test-server := TestArtemisServer server-config backdoor
    block.call test-server
  else if type == "http":
    with-http-artemis-server block
  else:
    throw "Unknown Artemis server type: $type"

class ToitHttpBackdoor implements ArtemisServerBackdoor:
  server/HttpArtemisServer

  constructor .server:

  fetch-device-information --hardware-id/uuid.Uuid -> List:
    entry/DeviceEntry := server.devices["$hardware-id"]
    return [
      uuid.parse entry.id,
      uuid.parse entry.organization-id,
      uuid.parse entry.alias,
    ]

  has-event --hardware-id/uuid.Uuid --type/string -> bool:
    hardware-id-string := "$hardware-id"
    server.events.do: | entry/EventEntry |
      if entry.device-id == hardware-id-string and
          entry.data is Map and (entry.data.get "type") == type:
        return true
    return false

  install-service-images images/List -> none:
    image-binaries := {:}
    sdk-service-versions := []
    images.do: | entry/Map |
      sdk-service-versions.add {
        "sdk_version": entry["sdk_version"],
        "service_version": entry["service_version"],
        "image": entry["image"],
      }
      image-binaries[entry["image"]] = entry["content"]

    server.sdk-service-versions = sdk-service-versions
    server.image-binaries = image-binaries

  create-device --organization-id/uuid.Uuid -> Map:
    // TODO(florian): the server should automatically generate an alias
    // if none is given.
    alias := random-uuid
    response := server.create-device-in-organization {
      "organization_id": "$organization-id",
      "alias": "$alias",
    }
    return {
      "id": uuid.parse response["id"],
      "alias": uuid.parse response["alias"],
    }

  remove-device device-id/uuid.Uuid -> none:
    server.remove-device "$device-id"

with-http-artemis-server [block]:
  server := http-servers.HttpArtemisServer 0
  port-latch := monitor.Latch
  server-task := task:: server.start port-latch

  host := "localhost"
  lan-ip := get-lan-ip
  host = host.replace "localhost" lan-ip

  server-config := ServerConfigHttp "test-artemis-server"
      --host=host
      --port=port-latch.get
      --path="/"
      --root-certificate-names=null
      --root-certificate-ders=null
      --poll-interval=Duration --ms=500
      --admin-headers={
        "X-Artemis-Header": "true",
      }
      --device-headers={
        "X-Artemis-Header": "true",
      }

  server.create-organization
      --id="$TEST-ORGANIZATION-UUID"
      --name=TEST-ORGANIZATION-NAME
      --admin-id="$TEST-EXAMPLE-COM-UUID"

  server.create-user
      --name=TEST-EXAMPLE-COM-NAME
      --email=TEST-EXAMPLE-COM-EMAIL
      --id="$TEST-EXAMPLE-COM-UUID"
  server.create-user
      --name=DEMO-EXAMPLE-COM-NAME
      --email=DEMO-EXAMPLE-COM-EMAIL
      --id="$DEMO-EXAMPLE-COM-UUID"
  server.create-user
      --name=ADMIN-NAME
      --email=ADMIN-EMAIL
      --id="$ADMIN-UUID"

  backdoor/ToitHttpBackdoor := ToitHttpBackdoor server

  test-server := TestArtemisServer server-config backdoor
  try:
    block.call test-server
  finally:
    server.close
    server-task.cancel

class SupabaseBackdoor implements ArtemisServerBackdoor:
  server-config_/ServerConfigSupabase
  service-key_/string

  constructor .server-config_ .service-key_:

  fetch-device-information --hardware-id/uuid.Uuid -> List:
    entry := query_ "devices" [
      equals "id" "$hardware-id",
    ]
    return [
      uuid.parse entry[0]["id"],
      uuid.parse entry[0]["organization_id"],
      uuid.parse entry[0]["alias"],
    ]

  has-event --hardware-id/uuid.Uuid --type/string -> bool:
    // For simplicity just run through all entries.
    // In the test-setup we should not have that many.
    entries := query_ "events" [
      equals "device_id" "$hardware-id",
    ]
    if not entries: return false
    entries.do:
      if it["data"] is Map and
          (it["data"].get "type") == type:
        return true
    return false

  install-service-images images/List -> none:
    with-backdoor-client_: | client/supabase.Client |
      // Clear the sdks, service-versions and images table.
      // Deletes require a where clause, so we use a filter that matches all IDs.
      filter := greater-than-or-equal "id" 0
      client.rest.delete "sdks" --filters=[filter]
      client.rest.delete "artemis_services" --filters=[filter]
      client.rest.delete "service_images" --filters=[filter]

      sdk-versions := {:}
      service-versions := {:}

      images.do: | entry/Map |
        sdk-version := entry["sdk_version"]
        service-version := entry["service_version"]
        image := entry["image"]
        content := entry["content"]

        sdk-id := sdk-versions.get sdk-version --init=:
          new-entry := client.rest.insert "sdks" {
            "version": sdk-version,
          }
          new-entry["id"]
        service-id := service-versions.get service-version --init=:
          new-entry := client.rest.insert "artemis_services" {
            "version": service-version,
          }
          new-entry["id"]

        client.rest.insert "service_images" {
          "sdk_id": sdk-id,
          "service_id": service-id,
          "image": image,
        }

        client.storage.upload --path="service-images/$image" --content=content

  create-device --organization-id/uuid.Uuid -> Map:
    alias := random-uuid
    with-backdoor-client_: | client/supabase.Client |
      response := client.rest.insert "devices" {
        "organization_id": "$organization-id",
        "alias": "$alias",
      }
      return {
        "id": uuid.parse response["id"],
        "alias": uuid.parse response["alias"],
      }
    unreachable

  remove-device device-id/uuid.Uuid -> none:
    with-backdoor-client_: | client/supabase.Client |
      client.rest.delete "devices" --filters=[equals "id" "$device-id"]

  query_ table/string filters/List=[] -> List?:
    with-backdoor-client_: | client/supabase.Client |
      return client.rest.select table --filters=filters
    unreachable

  with-backdoor-client_ [block]:
    network := net.open
    supabase-client/supabase.Client? := null
    try:
      supabase-client = supabase.Client
          --host=server-config_.host
          --anon=service-key_
      block.call supabase-client
    finally:
      if supabase-client: supabase-client.close
      network.close
