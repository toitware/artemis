// Copyright (C) 2026 Toit contributors.

// Exercises the AdminBrokerCli interface against a Supabase broker that
// provides admin operations (org/profile/member management). Replaces
// the historical artemis-server-test, which exercised the old standalone
// ArtemisServerCli interface that has since been folded into the broker.

import cli show Cli
import expect show *
import uuid show Uuid

import .artemis-server
import .utils

import artemis.cli.brokers.broker show BrokerCli AdminBrokerCli with-broker

main args:
  with-artemis-server --args=args --type="supabase": | artemis-server/TestArtemisServer |
    run-test artemis-server --authenticate=: | admin/AdminBrokerCli |
      admin.sign-in
            --email=TEST-EXAMPLE-COM-EMAIL
            --password=TEST-EXAMPLE-COM-PASSWORD

run-test artemis-server/TestArtemisServer [--authenticate]:
  server-config := artemis-server.server-config
  with-tmp-config-cli: | cli/Cli |
    with-broker server-config --cli=cli: | broker/BrokerCli |
      if broker is not AdminBrokerCli:
        throw "Test broker does not support admin operations."
      admin := broker as AdminBrokerCli
      authenticate.call admin
      test-create-device-in-organization admin
      test-organizations admin
      test-profile admin

test-create-device-in-organization admin/AdminBrokerCli -> Uuid:
  // Test without and with alias.
  device1 := admin.create-device-in-organization
      --device-id=null
      --organization-id=TEST-ORGANIZATION-UUID
  expect-equals TEST-ORGANIZATION-UUID device1.organization-id

  alias-id := random-uuid
  device2 := admin.create-device-in-organization
      --device-id=alias-id
      --organization-id=TEST-ORGANIZATION-UUID
  expect-equals TEST-ORGANIZATION-UUID device2.organization-id
  expect-equals alias-id device2.id

  return device2.hardware-id

test-organizations admin/AdminBrokerCli:
  original-orgs := admin.get-organizations

  // For now we can't be sure that there aren't other organizations from
  // previous runs of the test.
  // Just ensure that there is at least one.
  expect original-orgs.size >= 1  // The prefilled organization.
  expect (original-orgs.any: it.id == TEST-ORGANIZATION-UUID)

  org := admin.create-organization "Testy"
  expect-equals "Testy" org.name
  expect-not-equals "" org.id
  expect-not (original-orgs.any: it.id == org.id)

  new-orgs := admin.get-organizations
  expect-equals (original-orgs.size + 1) new-orgs.size
  original-orgs.do: | old-org |
    expect (new-orgs.any: it.id == old-org.id)
  expect (new-orgs.any: it.id == org.id)

  detailed := admin.get-organization org.id
  expect-equals org.id detailed.id
  expect-equals org.name detailed.name
  expect (detailed.created-at < Time.now)

  non-existent := admin.get-organization NON-EXISTENT-UUID
  expect-null non-existent

  // Test member functions.
  current-user-id := TEST-EXAMPLE-COM-UUID
  demo-user-id := DEMO-EXAMPLE-COM-UUID

  members := admin.get-organization-members org.id
  expect-equals 1 members.size
  expect-equals current-user-id members[0]["id"]
  expect-equals "admin" members[0]["role"]

  // Add a new member.
  admin.organization-member-add
      --organization-id=org.id
      --user-id=demo-user-id
      --role="member"
  members = admin.get-organization-members org.id
  expect-equals 2 members.size
  expect members[0]["id"] != members[1]["id"]
  members.do: | member |
    if member["id"] == current-user-id:
      expect-equals "admin" member["role"]
    else:
      expect-equals demo-user-id member["id"]
      expect-equals "member" member["role"]

  // Update the role of the new member.
  admin.organization-member-set-role
      --organization-id=org.id
      --user-id=demo-user-id
      --role="admin"
  members = admin.get-organization-members org.id
  expect-equals 2 members.size
  expect members[0]["id"] != members[1]["id"]
  members.do: | member |
    id := member["id"]
    expect (id == current-user-id or id == demo-user-id)
    expect-equals "admin" member["role"]

  // Remove the new member.
  admin.organization-member-remove
      --organization-id=org.id
      --user-id=demo-user-id

  members = admin.get-organization-members org.id
  expect-equals 1 members.size
  expect-equals current-user-id members[0]["id"]
  expect-equals "admin" members[0]["role"]

  // Add the new member with admin role.
  admin.organization-member-add
      --organization-id=org.id
      --user-id=demo-user-id
      --role="admin"
  members = admin.get-organization-members org.id
  expect-equals 2 members.size
  expect members[0]["id"] != members[1]["id"]
  members.do: | member |
    id := member["id"]
    expect (id == current-user-id or id == demo-user-id)
    expect-equals "admin" member["role"]

  // Keep the demo user in the same organization as the test user,
  // so we can read the user's profile in 'test-profile'.

test-profile admin/AdminBrokerCli:
  profile := admin.get-profile

  profile = admin.get-profile
  expect-equals "Test User" profile["name"]
  id := profile["id"]

  admin.update-profile --name="Test User updated"
  profile = admin.get-profile
  expect-equals "Test User updated" profile["name"]

  profile2 := admin.get-profile --user-id=id
  expect-equals profile["id"] profile2["id"]
  expect-equals profile["name"] profile2["name"]
  expect-equals profile["email"] profile2["email"]

  // Change it back.
  // Other tests might need the profile to be in a certain state.
  admin.update-profile --name="Test User"

  profile-non-existent := admin.get-profile --user-id=NON-EXISTENT-UUID
  expect-null profile-non-existent

  // The following test requires that we have added the demo user
  // and test user into the same organization.
  profile-demo := admin.get-profile --user-id=DEMO-EXAMPLE-COM-UUID
  expect-equals DEMO-EXAMPLE-COM-NAME profile-demo["name"]
