// Copyright (C) 2022 Toitware ApS. All rights reserved.

import expect show *
import host.directory
import log
import net

import .supabase_local_server

import artemis.cli.artemis_servers.artemis_server show ArtemisServerCli
import artemis.service.artemis_servers.artemis_server show ArtemisServerService
import artemis.shared.server_config show ServerConfig

import .utils

interface ArtemisServerBackdoor:
  /**
  Fetches the information of the device with the given $hardware_id.

  Returns a list of [hardware_id, fleet_id, alias]. If no alias exists, uses "" instead.
  */
  fetch_device_information --hardware_id/string -> List

  /** Whether there exists a '$type'-event for the given $hardware_id. */
  has_event --hardware_id/string --type/string -> bool

run_test server_config/ServerConfig backdoor/ArtemisServerBackdoor
    [--authenticate]:
  with_tmp_config: | config |
    network := net.open
    authenticate.call config
    server_cli := ArtemisServerCli network server_config config
    hardware_id := test_create_device_in_organization server_cli backdoor
    test_notify_created server_cli backdoor --hardware_id=hardware_id
    server_service := ArtemisServerService server_config --hardware_id=hardware_id
    test_check_in network server_service backdoor --hardware_id=hardware_id

    test_organizations server_cli backdoor


test_create_device_in_organization server_cli/ArtemisServerCli backdoor/ArtemisServerBackdoor -> string:
  // Test without and with alias.
  device1 := server_cli.create_device_in_organization
      --device_id=""
      --organization_id=TEST_ORGANIZATION_UUID
  hardware_id1 := device1.hardware_id
  data := backdoor.fetch_device_information --hardware_id=hardware_id1
  expect_equals hardware_id1 data[0]
  expect_equals TEST_ORGANIZATION_UUID data[1]
  // The alias is auto-filled to some UUID in the supabase database.
  // TODO(florian): check that this is always the case? (in which case we would
  // need to fix the http server).

  device2 := server_cli.create_device_in_organization
      --device_id="Testy"
      --organization_id=TEST_ORGANIZATION_UUID
  sleep --ms=200
  hardware_id2 := device2.hardware_id
  data = backdoor.fetch_device_information --hardware_id=hardware_id2
  expect_equals hardware_id2 data[0]
  expect_equals TEST_ORGANIZATION_UUID data[1]
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

test_organizations server_cli/ArtemisServerCli backdoor/ArtemisServerBackdoor:
  original_orgs := server_cli.get_organizations

  // For now we can't be sure that there aren't other organizations from
  // previous runs of the test.
  // Just ensure that there is at least one.
  expect original_orgs.size >= 1  // The prefilled organization.
  expect (original_orgs.any: it.id == TEST_ORGANIZATION_UUID)

  org := server_cli.create_organization "Testy"
  expect_equals "Testy" org.name
  expect_not_equals "" org.id
  expect_not (original_orgs.any: it.id == org.id)

  new_orgs := server_cli.get_organizations
  expect_equals (original_orgs.size + 1) new_orgs.size
  original_orgs.do: | old_org |
    expect (new_orgs.any: it.id == old_org.id)
  expect (new_orgs.any: it.id == org.id)
