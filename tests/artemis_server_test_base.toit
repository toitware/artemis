// Copyright (C) 2022 Toitware ApS. All rights reserved.

import expect show *
import host.directory
import log
import net

import .supabase_local_server

import artemis.cli.artemis_servers.artemis_server show ArtemisServerCli
import artemis.service.artemis_servers.artemis_server show ArtemisServerService
import artemis.shared.server_config show ServerConfig

interface ArtemisServerBackdoor:
  /**
  Fetches the information of the device with the given $hardware_id.

  Returns a list of [hardware_id, fleet_id, alias]. If no alias exists, uses "" instead.
  */
  fetch_device_information --hardware_id/string -> List

  /** Whether there exists a '$type'-event for the given $hardware_id. */
  has_event --hardware_id/string --type/string -> bool


/** An organization ID that was already added to the Supabase server. */
ORGANIZATION_ID ::= "eb45c662-356c-4bea-ad8c-ede37688fddf"

run_test server_config/ServerConfig backdoor/ArtemisServerBackdoor:
  network := net.open
  server_cli := ArtemisServerCli network server_config
  hardware_id := test_create_device_in_fleet server_cli backdoor
  test_notify_created server_cli backdoor --hardware_id=hardware_id
  server_service := ArtemisServerService server_config --hardware_id=hardware_id
  test_check_in network server_service backdoor --hardware_id=hardware_id


test_create_device_in_fleet server_cli/ArtemisServerCli backdoor/ArtemisServerBackdoor -> string:
  // Test without and with alias.
  hardware_id1 := server_cli.create_device_in_organization
      --device_id=""
      --organization_id=ORGANIZATION_ID
  data := backdoor.fetch_device_information --hardware_id=hardware_id1
  expect_equals hardware_id1 data[0]
  expect_equals ORGANIZATION_ID data[1]
  // The alias is auto-filled to some UUID in the postgres database.
  // TODO(florian): check that this is always the case? (in which case we would
  // need to fix the http server).

  hardware_id2 := server_cli.create_device_in_organization
      --device_id="Testy"
      --organization_id=ORGANIZATION_ID
  sleep --ms=200
  data = backdoor.fetch_device_information --hardware_id=hardware_id2
  expect_equals hardware_id2 data[0]
  expect_equals ORGANIZATION_ID data[1]
  expect_equals "Testy" data[2]

  return hardware_id2

test_notify_created server_cli/ArtemisServerCli backdoor/ArtemisServerBackdoor --hardware_id/string:
  expect_not (backdoor.has_event --hardware_id=hardware_id --type="created")
  server_cli.notify_created --hardware_id=hardware_id
  expect (backdoor.has_event --hardware_id=hardware_id --type="created")

test_check_in network/net.Interface
    server_service/ArtemisServerService
    backdoor/ArtemisServerBackdoor
    --hardware_id/string:
  expect_not (backdoor.has_event --hardware_id=hardware_id --type="ping")
  server_service.check_in network log.default
  expect (backdoor.has_event --hardware_id=hardware_id --type="ping")
