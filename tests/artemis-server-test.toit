// Copyright (C) 2022 Toitware ApS. All rights reserved.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import cli show Cli
import expect show *
import host.directory
import log
import net
import uuid

import .artemis-server
import .utils

import artemis.cli.artemis-servers.artemis-server show ArtemisServerCli
import artemis.service.artemis-servers.artemis-server show ArtemisServerService
import artemis.shared.server-config show ServerConfig
import artemis.cli.auth as cli-auth

main args:
  server-type := ?
  if args.is-empty:
    server-type = "http"
  else if args[0] == "--http-server":
    server-type = "http"
  else if args[0] == "--supabase-server":
    server-type = "supabase"
  else:
    throw "Unknown server server type: $args[0]"
  with-artemis-server --args=args --type=server-type: | artemis-server/TestArtemisServer |
    run-test artemis-server --authenticate=: | server/ArtemisServerCli |
      server.sign-in
            --email=TEST-EXAMPLE-COM-EMAIL
            --password=TEST-EXAMPLE-COM-PASSWORD

run-test artemis-server/TestArtemisServer [--authenticate]:
  server-config := artemis-server.server-config
  backdoor := artemis-server.backdoor
  with-tmp-config-cli: | cli/Cli |
    network := net.open
    server-cli := ArtemisServerCli network server-config --cli=cli
    authenticate.call server-cli
    hardware-id := test-create-device-in-organization server-cli backdoor
    test-notify-created server-cli backdoor --hardware-id=hardware-id
    server-service := ArtemisServerService server-config --hardware-id=hardware-id
    test-check-in network server-service backdoor --hardware-id=hardware-id

    test-organizations server-cli backdoor
    test-profile server-cli backdoor
    test-sdk server-cli backdoor

test-create-device-in-organization server-cli/ArtemisServerCli backdoor/ArtemisServerBackdoor -> uuid.Uuid:
  // Test without and with alias.
  device1 := server-cli.create-device-in-organization
      --device-id=null
      --organization-id=TEST-ORGANIZATION-UUID
  hardware-id1 := device1.hardware-id
  data := backdoor.fetch-device-information --hardware-id=hardware-id1
  expect-equals hardware-id1 data[0]
  expect-equals TEST-ORGANIZATION-UUID data[1]

  alias-id := random-uuid
  device2 := server-cli.create-device-in-organization
      --device-id=alias-id
      --organization-id=TEST-ORGANIZATION-UUID
  sleep --ms=200
  hardware-id2 := device2.hardware-id
  data = backdoor.fetch-device-information --hardware-id=hardware-id2
  expect-equals hardware-id2 data[0]
  expect-equals TEST-ORGANIZATION-UUID data[1]
  expect-equals alias-id data[2]

  return hardware-id2

test-notify-created server-cli/ArtemisServerCli backdoor/ArtemisServerBackdoor --hardware-id/uuid.Uuid:
  expect-not (backdoor.has-event --hardware-id=hardware-id --type="created")
  server-cli.notify-created --hardware-id=hardware-id
  expect (backdoor.has-event --hardware-id=hardware-id --type="created")

test-check-in network/net.Interface
    server-service/ArtemisServerService
    backdoor/ArtemisServerBackdoor
    --hardware-id/uuid.Uuid:
  expect-not (backdoor.has-event --hardware-id=hardware-id --type="ping")
  server-service.check-in network log.default
  expect (backdoor.has-event --hardware-id=hardware-id --type="ping")

test-organizations server-cli/ArtemisServerCli backdoor/ArtemisServerBackdoor:
  original-orgs := server-cli.get-organizations

  // For now we can't be sure that there aren't other organizations from
  // previous runs of the test.
  // Just ensure that there is at least one.
  expect original-orgs.size >= 1  // The prefilled organization.
  expect (original-orgs.any: it.id == TEST-ORGANIZATION-UUID)

  org := server-cli.create-organization "Testy"
  expect-equals "Testy" org.name
  expect-not-equals "" org.id
  expect-not (original-orgs.any: it.id == org.id)

  new-orgs := server-cli.get-organizations
  expect-equals (original-orgs.size + 1) new-orgs.size
  original-orgs.do: | old-org |
    expect (new-orgs.any: it.id == old-org.id)
  expect (new-orgs.any: it.id == org.id)

  detailed := server-cli.get-organization org.id
  expect-equals org.id detailed.id
  expect-equals org.name detailed.name
  expect (detailed.created-at < Time.now)

  non-existent := server-cli.get-organization NON-EXISTENT-UUID
  expect-null non-existent

  // Test member functions.
  current-user-id := TEST-EXAMPLE-COM-UUID
  demo-user-id := DEMO-EXAMPLE-COM-UUID

  members := server-cli.get-organization-members org.id
  expect-equals 1 members.size
  expect-equals current-user-id members[0]["id"]
  expect-equals "admin" members[0]["role"]

  // Add a new member.
  server-cli.organization-member-add
      --organization-id=org.id
      --user-id=demo-user-id
      --role="member"
  members = server-cli.get-organization-members org.id
  expect-equals 2 members.size
  expect members[0]["id"] != members[1]["id"]
  members.do: | member |
    if member["id"] == current-user-id:
      expect-equals "admin" member["role"]
    else:
      expect-equals demo-user-id member["id"]
      expect-equals "member" member["role"]

  // Update the role of the new member.
  server-cli.organization-member-set-role
      --organization-id=org.id
      --user-id=demo-user-id
      --role="admin"
  members = server-cli.get-organization-members org.id
  expect-equals 2 members.size
  expect members[0]["id"] != members[1]["id"]
  members.do: | member |
    id := member["id"]
    expect (id == current-user-id or id == demo-user-id)
    expect-equals "admin" member["role"]

  // Remove the new member.
  server-cli.organization-member-remove
      --organization-id=org.id
      --user-id=demo-user-id

  members = server-cli.get-organization-members org.id
  expect-equals 1 members.size
  expect-equals current-user-id members[0]["id"]
  expect-equals "admin" members[0]["role"]

  // Add the new member with admin role.
  server-cli.organization-member-add
      --organization-id=org.id
      --user-id=demo-user-id
      --role="admin"
  members = server-cli.get-organization-members org.id
  expect-equals 2 members.size
  expect members[0]["id"] != members[1]["id"]
  members.do: | member |
    id := member["id"]
    expect (id == current-user-id or id == demo-user-id)
    expect-equals "admin" member["role"]

  // Keep the demo user in the same organization as the test user,
  // so we can read the user's profile in 'test_profile'

test-profile server-cli/ArtemisServerCli backdoor/ArtemisServerBackdoor:
  profile := server-cli.get-profile

  profile = server-cli.get-profile
  expect-equals "Test User" profile["name"]
  id := profile["id"]

  server-cli.update-profile --name="Test User updated"
  profile = server-cli.get-profile
  expect-equals "Test User updated" profile["name"]

  profile2 := server-cli.get-profile --user-id=id
  expect-equals profile["id"] profile2["id"]
  expect-equals profile["name"] profile2["name"]
  expect-equals profile["email"] profile2["email"]

  // Change it back.
  // Other tests might need the profile to be in a certain state.
  server-cli.update-profile --name="Test User"

  profile-non-existent := server-cli.get-profile --user-id=NON-EXISTENT-UUID
  expect-null profile-non-existent

  // The following test requires that we have added the demo user
  // and test user into the same organization.
  profile-demo := server-cli.get-profile --user-id=DEMO-EXAMPLE-COM-UUID
  expect-equals DEMO-EXAMPLE-COM-NAME profile-demo["name"]

test-sdk server-cli/ArtemisServerCli backdoor/ArtemisServerBackdoor:
  SDK-V1 ::= "v2.0.0-alpha.46"
  SDK-V2 ::= "v2.0.0-alpha.47"
  SERVICE-V1 ::= "v0.0.1"
  SERVICE-V2 ::= "v0.0.2"

  IMAGE-V1-V1 ::= "foobar"
  IMAGE-V2-V1 ::= "toto"
  IMAGE-V2-V2 ::= "titi"

  CONTENT-V1-V1 ::= "foobar_content".to-byte-array
  CONTENT-V2-V1 ::= "toto_content".to-byte-array
  CONTENT-V2-V2 ::= "titi_content".to-byte-array

  test-images := [
    {
      "sdk_version": SDK-V1,
      "service_version": SERVICE-V1,
      "image": IMAGE-V1-V1,
      "content": CONTENT-V1-V1,
    },
    {
      "sdk_version": SDK-V2,
      "service_version": SERVICE-V1,
      "image": IMAGE-V2-V1,
      "content": CONTENT-V2-V1,
    },
    {
      "sdk_version": SDK-V2,
      "service_version": SERVICE-V2,
      "image": IMAGE-V2-V2,
      "content": CONTENT-V2-V2,
    },
  ]
  backdoor.install-service-images test-images

  images := server-cli.list-sdk-service-versions --organization-id=TEST-ORGANIZATION-UUID
  expect-equals test-images.size images.size

  test-images.do: | test-image |
    filtered-image := images.filter: | image |
      image["sdk_version"] == test-image["sdk_version"] and
        image["service_version"] == test-image["service_version"]
    expect-equals 1 filtered-image.size
    image := filtered-image[0]["image"]
    expect-equals test-image["image"] image

    downloaded-content := server-cli.download-service-image image
    expect-equals test-image["content"] downloaded-content

  // Test that the filters on list_sdk_service_versions work.
  images = server-cli.list-sdk-service-versions
      --organization-id=TEST-ORGANIZATION-UUID
      --sdk-version=SDK-V1
  expect-equals 1 images.size
  expect-equals SDK-V1 images[0]["sdk_version"]
  expect-equals SERVICE-V1 images[0]["service_version"]

  images = server-cli.list-sdk-service-versions
      --organization-id=TEST-ORGANIZATION-UUID
      --sdk-version=SDK-V2
  expect-equals 2 images.size
  images.do: | image |
    expect-equals SDK-V2 image["sdk_version"]
    expect (image["service_version"] == SERVICE-V1 or
        image["service_version"] == SERVICE-V2)

  images = server-cli.list-sdk-service-versions
      --organization-id=TEST-ORGANIZATION-UUID
      --service-version=SERVICE-V1
  expect-equals 2 images.size
  images.do: | image |
    expect-equals SERVICE-V1 image["service_version"]
    expect (image["sdk_version"] == SDK-V1 or
        image["sdk_version"] == SDK-V2)

  images = server-cli.list-sdk-service-versions
      --organization-id=TEST-ORGANIZATION-UUID
      --service-version=SERVICE-V2
  expect-equals 1 images.size
  expect-equals SERVICE-V2 images[0]["service_version"]
  expect-equals SDK-V2 images[0]["sdk_version"]

  images = server-cli.list-sdk-service-versions
      --organization-id=TEST-ORGANIZATION-UUID
      --sdk-version=SDK-V2
      --service-version=SERVICE-V1
  expect-equals 1 images.size
  expect-equals SERVICE-V1 images[0]["service_version"]
  expect-equals SDK-V2 images[0]["sdk_version"]
