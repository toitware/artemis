// Copyright (C) 2022 Toitware ApS. All rights reserved.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import expect show *
import host.directory
import log
import net

import .artemis_server
import .utils

import artemis.cli.artemis_servers.artemis_server show ArtemisServerCli
import artemis.service.artemis_servers.artemis_server show ArtemisServerService
import artemis.shared.server_config show ServerConfig
import artemis.cli.auth as cli_auth

main args:
  server_type := ?
  if args.is_empty:
    server_type = "http"
  else if args[0] == "--http-server":
    server_type = "http"
  else if args[0] == "--supabase-server":
    server_type = "supabase"
  else:
    throw "Unknown server server type: $args[0]"
  with_artemis_server --type=server_type: | artemis_server/TestArtemisServer |
    run_test artemis_server --authenticate=: | server/ArtemisServerCli |
      server.sign_in
            --email=TEST_EXAMPLE_COM_EMAIL
            --password=TEST_EXAMPLE_COM_PASSWORD

run_test artemis_server/TestArtemisServer [--authenticate]:
  server_config := artemis_server.server_config
  backdoor := artemis_server.backdoor
  with_tmp_config: | config |
    network := net.open
    server_cli := ArtemisServerCli network server_config config
    authenticate.call server_cli
    hardware_id := test_create_device_in_organization server_cli backdoor
    test_notify_created server_cli backdoor --hardware_id=hardware_id
    server_service := ArtemisServerService server_config --hardware_id=hardware_id
    test_check_in network server_service backdoor --hardware_id=hardware_id

    test_organizations server_cli backdoor
    test_profile server_cli backdoor
    test_sdk server_cli backdoor

test_create_device_in_organization server_cli/ArtemisServerCli backdoor/ArtemisServerBackdoor -> string:
  // Test without and with alias.
  device1 := server_cli.create_device_in_organization
      --device_id=""
      --organization_id=TEST_ORGANIZATION_UUID
  hardware_id1 := device1.hardware_id
  data := backdoor.fetch_device_information --hardware_id=hardware_id1
  expect_equals hardware_id1 data[0]
  expect_equals TEST_ORGANIZATION_UUID data[1]

  alias_id := random_uuid_string
  device2 := server_cli.create_device_in_organization
      --device_id=alias_id
      --organization_id=TEST_ORGANIZATION_UUID
  sleep --ms=200
  hardware_id2 := device2.hardware_id
  data = backdoor.fetch_device_information --hardware_id=hardware_id2
  expect_equals hardware_id2 data[0]
  expect_equals TEST_ORGANIZATION_UUID data[1]
  expect_equals alias_id data[2]

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

  detailed := server_cli.get_organization org.id
  expect_equals org.id detailed.id
  expect_equals org.name detailed.name
  expect (detailed.created_at < Time.now)

  non_existent := server_cli.get_organization NON_EXISTENT_UUID
  expect_null non_existent

  // Test member functions.
  current_user_id := TEST_EXAMPLE_COM_UUID
  demo_user_id := DEMO_EXAMPLE_COM_UUID

  members := server_cli.get_organization_members org.id
  expect_equals 1 members.size
  expect_equals current_user_id members[0]["id"]
  expect_equals "admin" members[0]["role"]

  // Add a new member.
  server_cli.organization_member_add
      --organization_id=org.id
      --user_id=demo_user_id
      --role="member"
  members = server_cli.get_organization_members org.id
  expect_equals 2 members.size
  expect members[0]["id"] != members[1]["id"]
  members.do: | member |
    if member["id"] == current_user_id:
      expect_equals "admin" member["role"]
    else:
      expect_equals demo_user_id member["id"]
      expect_equals "member" member["role"]

  // Update the role of the new member.
  server_cli.organization_member_set_role
      --organization_id=org.id
      --user_id=demo_user_id
      --role="admin"
  members = server_cli.get_organization_members org.id
  expect_equals 2 members.size
  expect members[0]["id"] != members[1]["id"]
  members.do: | member |
    id := member["id"]
    expect (id == current_user_id or id == demo_user_id)
    expect_equals "admin" member["role"]

  // Remove the new member.
  server_cli.organization_member_remove
      --organization_id=org.id
      --user_id=demo_user_id

  members = server_cli.get_organization_members org.id
  expect_equals 1 members.size
  expect_equals current_user_id members[0]["id"]
  expect_equals "admin" members[0]["role"]

  // Add the new member with admin role.
  server_cli.organization_member_add
      --organization_id=org.id
      --user_id=demo_user_id
      --role="admin"
  members = server_cli.get_organization_members org.id
  expect_equals 2 members.size
  expect members[0]["id"] != members[1]["id"]
  members.do: | member |
    id := member["id"]
    expect (id == current_user_id or id == demo_user_id)
    expect_equals "admin" member["role"]

  // Keep the demo user in the same organization as the test user,
  // so we can read the user's profile in 'test_profile'

test_profile server_cli/ArtemisServerCli backdoor/ArtemisServerBackdoor:
  profile := server_cli.get_profile
  // If we have run the test before, we can't know what value the profile
  // currently has.

  server_cli.update_profile --name="Test User updated"
  profile = server_cli.get_profile
  expect_equals "Test User updated" profile["name"]
  id := profile["id"]

  profile2 := server_cli.get_profile --user_id=id
  expect_equals profile["id"] profile2["id"]
  expect_equals profile["name"] profile2["name"]
  expect_equals profile["email"] profile2["email"]

  profile_non_existent := server_cli.get_profile --user_id=NON_EXISTENT_UUID
  expect_null profile_non_existent

  // The following test requires that we have added the demo user
  // and test user into the same organization.
  profile_demo := server_cli.get_profile --user_id=DEMO_EXAMPLE_COM_UUID
  expect_equals DEMO_EXAMPLE_COM_NAME profile_demo["name"]

test_sdk server_cli/ArtemisServerCli backdoor/ArtemisServerBackdoor:
  SDK_V1 ::= "v2.0.0-alpha.46"
  SDK_V2 ::= "v2.0.0-alpha.47"
  SERVICE_V1 ::= "v0.0.1"
  SERVICE_V2 ::= "v0.0.2"

  IMAGE_V1_V1 ::= "foobar"
  IMAGE_V2_V1 ::= "toto"
  IMAGE_V2_V2 ::= "titi"

  CONTENT_V1_V1 ::= "foobar_content".to_byte_array
  CONTENT_V2_V1 ::= "toto_content".to_byte_array
  CONTENT_V2_V2 ::= "titi_content".to_byte_array

  test_images := [
    {
      "sdk_version": SDK_V1,
      "service_version": SERVICE_V1,
      "image": IMAGE_V1_V1,
      "content": CONTENT_V1_V1,
    },
    {
      "sdk_version": SDK_V2,
      "service_version": SERVICE_V1,
      "image": IMAGE_V2_V1,
      "content": CONTENT_V2_V1,
    },
    {
      "sdk_version": SDK_V2,
      "service_version": SERVICE_V2,
      "image": IMAGE_V2_V2,
      "content": CONTENT_V2_V2,
    },
  ]
  backdoor.install_service_images test_images

  images := server_cli.list_sdk_service_versions
  expect_equals test_images.size images.size

  test_images.do: | test_image |
    filtered_image := images.filter: | image |
      image["sdk_version"] == test_image["sdk_version"] and
        image["service_version"] == test_image["service_version"]
    expect_equals 1 filtered_image.size
    image := filtered_image[0]["image"]
    expect_equals test_image["image"] image

    downloaded_content := server_cli.download_service_image image
    expect_equals test_image["content"] downloaded_content

  // Test that the filters on list_sdk_service_versions work.
  images = server_cli.list_sdk_service_versions --sdk_version=SDK_V1
  expect_equals 1 images.size
  expect_equals SDK_V1 images[0]["sdk_version"]
  expect_equals SERVICE_V1 images[0]["service_version"]

  images = server_cli.list_sdk_service_versions --sdk_version=SDK_V2
  expect_equals 2 images.size
  images.do: | image |
    expect_equals SDK_V2 image["sdk_version"]
    expect (image["service_version"] == SERVICE_V1 or
        image["service_version"] == SERVICE_V2)

  images = server_cli.list_sdk_service_versions --service_version=SERVICE_V1
  expect_equals 2 images.size
  images.do: | image |
    expect_equals SERVICE_V1 image["service_version"]
    expect (image["sdk_version"] == SDK_V1 or
        image["sdk_version"] == SDK_V2)

  images = server_cli.list_sdk_service_versions --service_version=SERVICE_V2
  expect_equals 1 images.size
  expect_equals SERVICE_V2 images[0]["service_version"]
  expect_equals SDK_V2 images[0]["sdk_version"]

  images = server_cli.list_sdk_service_versions
      --sdk_version=SDK_V2
      --service_version=SERVICE_V1
  expect_equals 1 images.size
  expect_equals SERVICE_V1 images[0]["service_version"]
  expect_equals SDK_V2 images[0]["sdk_version"]
