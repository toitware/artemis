// Copyright (C) 2023 Toitware ApS. All rights reserved.

import monitor
import net
import supabase
import supabase.filter show equals greater-than-or-equal
import system
import uuid show Uuid

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
  Fetches the information of the device with the given $device-id.

  Returns a list of [device_id, fleet_id, alias]. If no alias exists, uses "" instead.
  */
  fetch-device-information --device-id/Uuid -> List

  /** Whether there exists a '$type'-event for the given $device-id. */
  has-event --device-id/Uuid --type/string -> bool

  /**
  Removes the device with the given $device-id.
  */
  remove-device device-id/Uuid -> none

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

  fetch-device-information --device-id/Uuid -> List:
    entry/DeviceEntry := server.devices["$device-id"]
    return [
      Uuid.parse entry.id,
      Uuid.parse entry.organization-id,
      Uuid.parse entry.alias,
    ]

  has-event --device-id/Uuid --type/string -> bool:
    device-id-string := "$device-id"
    server.events.do: | entry/EventEntry |
      if entry.device-id == device-id-string and
          entry.data is Map and (entry.data.get "type") == type:
        return true
    return false

  remove-device device-id/Uuid -> none:
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
      --use-tls=false
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

  fetch-device-information --device-id/Uuid -> List:
    entry := query_ "devices" [
      equals "id" "$device-id",
    ]
    return [
      Uuid.parse entry[0]["id"],
      Uuid.parse entry[0]["organization_id"],
      Uuid.parse entry[0]["alias"],
    ]

  has-event --device-id/Uuid --type/string -> bool:
    // For simplicity just run through all entries.
    // In the test-setup we should not have that many.
    entries := query_ "events" [
      equals "device_id" "$device-id",
    ]
    if not entries: return false
    entries.do:
      if it["data"] is Map and
          (it["data"].get "type") == type:
        return true
    return false

  remove-device device-id/Uuid -> none:
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
          --uri=server-config_.uri
          --anon=service-key_
      block.call supabase-client
    finally:
      if supabase-client: supabase-client.close
      network.close
