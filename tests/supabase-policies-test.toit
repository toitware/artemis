// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server-config as cli-server-config
import artemis.shared.server-config show ServerConfigSupabase
import expect show *
import supabase
import supabase.filter show equals greater-than-or-equal
import .artemis-server

main args:
  with-artemis-server --args=args --type="supabase": | artemis-server/TestArtemisServer |
    server-config := artemis-server.server-config as ServerConfigSupabase
    client-anon := supabase.Client --server-config=server-config
    client1 := supabase.Client --server-config=server-config
    client2 := supabase.Client --server-config=server-config
    client3 := supabase.Client --server-config=server-config
    client4 := supabase.Client --server-config=server-config

    emails := []
    [ client1, client2, client3, client4 ].do:
      email := "$(random)@toit.io"
      emails.add email
      password := "password"
      it.auth.sign-up --email=email --password=password
      // On local setups, the sign up does not need to be confirmed.
      it.auth.sign-in --email=email --password=password

    // Each user should only be able to see their own profile.
    users1 := client1.rest.select "profiles"
    expect-equals 1 users1.size
    user1 := users1[0]
    user-id1 := user1["id"]
    name1 := user1["name"]
    email1 := emails[0]
    users1-with-email := client1.rest.select "profiles_with_email"
    expect-equals 1 users1.size
    user1-with-email := users1-with-email[0]
    expect-equals user-id1 user1-with-email["id"]
    expect-equals name1 user1-with-email["name"]
    expect-equals email1 user1-with-email["email"]

    users2 := client2.rest.select "profiles"
    expect-equals 1 users2.size
    user2 := users2[0]
    user-id2 := user2["id"]
    name2 := user2["name"]
    email2 := emails[1]
    users2-with-email := client2.rest.select "profiles_with_email"
    expect-equals 1 users2.size
    user2-with-email := users2-with-email[0]
    expect-equals user-id2 user2-with-email["id"]
    expect-equals name2 user2-with-email["name"]
    expect-equals email2 user2-with-email["email"]

    users3 := client3.rest.select "profiles"
    expect-equals 1 users3.size
    user3 := users3[0]
    user-id3 := user3["id"]
    name3 := user3["name"]
    email3 := emails[2]
    users3-with-email := client3.rest.select "profiles_with_email"
    expect-equals 1 users3.size
    user3-with-email := users3-with-email[0]
    expect-equals user-id3 user3-with-email["id"]
    expect-equals name3 user3-with-email["name"]
    expect-equals email3 user3-with-email["email"]

    users4 := client4.rest.select "profiles"
    expect-equals 1 users4.size
    user4 := users4[0]
    user-id4 := user4["id"]
    name4 := user4["name"]
    email4 := emails[3]
    users4-with-email := client4.rest.select "profiles_with_email"
    expect-equals 1 users4.size
    user4-with-email := users4-with-email[0]
    expect-equals user-id4 user4-with-email["id"]
    expect-equals name4 user4-with-email["name"]
    expect-equals email4 user4-with-email["email"]

    // Anon should not be able to see any profile.
    users-anon := client-anon.rest.select "profiles"
    expect-equals 0 users-anon.size

    // Users can change their profile.
    client1.rest.update "profiles" --filters=[
      equals "id" "$user-id1",
    ] {
      "name": "$name1 + changed",
    }

    // Check the new name.
    users1 = client1.rest.select "profiles" --filters=[
      equals "id" "$user-id1",
    ]
    expect-equals 1 users1.size
    expect-equals "$name1 + changed" users1[0]["name"]

    // We don't give any way to change the email with the profile-with-email view.
    expect-throws --contains="cannot update":
      client1.rest.update "profiles_with_email" --filters=[
        equals "id" "$user-id1",
      ] {
        "email": "doesnt@work",
      }
    // The update didn't succeed.
    users1 = client1.rest.select "profiles_with_email" --filters=[
      equals "id" "$user-id1",
    ]
    expect-equals 1 users1.size
    expect-equals email1 users1[0]["email"]

    // We can't change the profile of a different user through the profile-with-email view.
    client1.rest.update "profiles_with_email" --filters=[
      equals "id" "$user-id2",
    ] {
      "name": "$name2 + won't change",
    }
    // The name is still the same.
    users2 = client2.rest.select "profiles_with_email" --filters=[
      equals "id" "$user-id2",
    ]
    expect-equals 1 users2.size
    expect-equals name2 users2[0]["name"]

    // Users can't change other profiles.
    // In fact, they can't even see them for update, which means that the
    // update here will succeed (the filter will find no matching
    // row, and thus not try to change anything).
    client2.rest.update "profiles" --filters=[
      equals "id" "$user-id1",
    ] {
      "name": "$name1 + NOPE",
    }
    users1 = client1.rest.select "profiles" --filters=[
      equals "id" "$user-id1",
    ]
    expect-equals 1 users1.size
    expect-equals "$name1 + changed" users1[0]["name"]

    // The same is true for the profiles_with_email view, which
    // is based on the profiles table.
    client2.rest.update "profiles_with_email" --filters=[
      equals "id" "$user-id1",
    ] {
      "name": "$name1 + NOPE",
    }

    // Create a new organization.
    organization := client1.rest.insert "organizations" {
      "name": "Test organization",
    }

    organization-id := organization["id"]

    // There should be an automatic 'admin' role for the user that
    // created the organization.
    roles := client1.rest.select "roles"
    expect-equals 1 roles.size
    role := roles[0]
    expect-equals "admin" role["role"]
    expect-equals organization-id role["organization_id"]
    expect-equals user-id1 role["user_id"]

    // The other clients should not be able to see the organization yet.
    organizations2 := client2.rest.select "organizations"
    expect-equals 0 organizations2.size

    // The anon client should not be able to see the organization.
    organizations-anon := client-anon.rest.select "organizations"
    expect-equals 0 organizations-anon.size

    // Admin can change the organization.
    // Using 'upsert' as 'update' hasn't been implemented at the time of
    // writing the test.
    client1.rest.upsert "organizations" {
      "id": organization-id,
      "name": "New name",
    }

    // Check the new name.
    organizations := client1.rest.select "organizations" --filters=[
      equals "id" "$organization-id",
    ]
    expect-equals 1 organizations.size
    expect-equals "New name" organizations[0]["name"]

    expect-throws --contains="policy": client2.rest.upsert "organizations" {
      "id": organization-id,
      "name": "New name client2",
    }

    // Anon can't change organization either.
    expect-throws --contains="policy": client-anon.rest.upsert "organizations" {
      "id": organization-id,
      "name": "New name anon",
    }

    // Make client2 a member.
    client1.rest.insert "roles" {
      "organization_id": organization-id,
      "user_id": user-id2,
      "role": "member",
    }

    /****************************************************************
    organization_id:
      client1 is admin.
      client2 is member.
    ****************************************************************/

    // There are now two members in the org:
    roles = client1.rest.select "roles"
    expect-equals 2 roles.size

    // Client2 can now see the organization.
    organizations2 = client2.rest.select "organizations"
    expect-equals 1 organizations2.size
    expect-equals organization-id organizations2[0]["id"]

    // Client2 can't change the organization.
    expect-throws --contains="policy": client2.rest.upsert "organizations" {
      "id": organization-id,
      "name": "New name client2",
    }

    // Client2 can't promote themself to admin.
    expect-throws --contains="policy": client2.rest.upsert "roles" {
      "organization_id": organization-id,
      "user_id": user-id2,
      "role": "admin",
    }

    // Client2 can't add a new member to the org.
    expect-throws --contains="policy": client2.rest.insert "roles" {
      "organization_id": organization-id,
      "user_id": user-id3,
      "role": "member",
    }

    // Both, client1 and client2 can now see the profiles of the other.
    users1 = client1.rest.select "profiles"
    expect-equals 2 users1.size
    expect (users1.any: it["id"] == user-id1)
    expect (users1.any: it["id"] == user-id2)

    users2 = client2.rest.select "profiles"
    expect-equals 2 users2.size
    expect (users2.any: it["id"] == user-id1)
    expect (users2.any: it["id"] == user-id2)

    // Both, client1 and client2, can insert devices.
    device1 := client1.rest.insert "devices" {
      "organization_id": organization-id,
    }
    device2 := client2.rest.insert "devices" {
      "organization_id": organization-id,
    }

    // Neither can update the profile of the other.
    client2.rest.update "profiles" --filters=[
      equals "id" "$user-id1",
    ] {
      "name": "$name1 + NOPE",
    }
    users1 = client1.rest.select "profiles" --filters=[
      equals "id" "$user-id1",
    ]
    expect users1[0]["name"] != "$name1 + NOPE"

    // Both can see the new devices.
    devices1 := client1.rest.select "devices" --filters=[
      equals "organization_id" "$organization-id",
    ]
    expect-equals 2 devices1.size

    devices2 := client2.rest.select "devices" --filters=[
      equals "organization_id" "$organization-id",
    ]
    expect-equals 2 devices2.size

    [device1, device2].do: |device|
      expect (devices1.any: it["id"] == device["id"])
      expect (devices2.any: it["id"] == device["id"])

    // Client3 and anon can't see the devices.
    devices3 := client3.rest.select "devices"
    expect-equals 0 devices3.size

    devices-anon := client-anon.rest.select "devices"
    expect-equals 0 devices-anon.size

    // Client3 can't insert a device.
    expect-throws --contains="policy": client3.rest.insert "devices" {
      "organization_id": organization-id,
    }

    // Anon can't insert a device.
    expect-throws --contains="policy": client-anon.rest.insert "devices" {
      "organization_id": organization-id,
    }

    // Make client2 an admin.
    client1.rest.update "roles" --filters=[
      equals "organization_id" "$organization-id",
      equals "user_id" "$user-id2",
    ] {
      "role": "admin",
    }

    /****************************************************************
    organization_id:
      client1 is admin.
      client2 is admin.
    ****************************************************************/

    // Client2 can now add a new member to the org.
    client2.rest.insert "roles" {
      "organization_id": organization-id,
      "user_id": user-id3,
      "role": "member",
    }

    /****************************************************************
    organization_id:
      client1 is admin.
      client2 is admin.
      client3 is member.
    ****************************************************************/

    // Client3 can now see the members.
    roles3 := client3.rest.select "roles"
    expect-equals 3 roles3.size

    // Client3 can now see the devices.
    devices3 = client3.rest.select "devices"
    expect-equals 2 devices3.size

    // Client3 can now insert a device.
    device3 := client3.rest.insert "devices" {
      "organization_id": organization-id,
    }

    // Client3 can now see the new device.
    devices3 = client3.rest.select "devices" --filters=[
      equals "id" "$device3["id"]",
    ]
    expect-equals 1 devices3.size

    // Users can be in multiple organizations.

    // User3 can create an organization that they are the admin of.
    organization3 := client3.rest.insert "organizations" {
      "name": "Organization 2",
    }
    organization3-id := organization3["id"]

    /****************************************************************
    organization_id:
      client1 is admin.
      client2 is admin.
      client3 is member.

    organization3_id:
      client3 is admin.
    ****************************************************************/

    // User3 can see the new organization.
    organizations3 := client3.rest.select "organizations"
    expect-equals 2 organizations3.size

    // User3 can see the new organization in the roles table.
    roles3 = client3.rest.select "roles"
    expect-equals 4 roles3.size

    // Client1, client2 and anon don't see the new organization.
    organizations1 := client1.rest.select "organizations"
    expect-equals 1 organizations1.size

    organizations2 = client2.rest.select "organizations"
    expect-equals 1 organizations2.size

    organizations-anon = client-anon.rest.select "organizations"
    expect-equals 0 organizations-anon.size

    // Client3 is admin of their organization, but not of the other one.
    expect-throws --contains="policy": client3.rest.upsert "organizations" {
      "id": organization-id,
      "name": "New name client3",
    }

    client3.rest.upsert "organizations" {
      "id": organization3-id,
      "name": "New name client3",
    }

    organizations3 = client3.rest.select "organizations" --filters=[
      equals "id" "$organization3-id",
    ]
    expect-equals "New name client3" organizations3[0]["name"]

    // Members can see the events of their devices.
    device1-events := client1.rest.select "events" --filters=[
      equals "device_id" "$device1["id"]",
    ]
    expect-equals 0 device1-events.size

    // Anon can insert into events, as long as the device_id is valid.
    // Note that we have to use the --no-return_inserted flag, because
    // anon can't see the inserted event.
    client-anon.rest.insert "events" --no-return-inserted {
      "device_id": device1["id"],
      "data": { "type": "test"},
    }

    // Now we have one event.
    device1-events = client1.rest.select "events" --filters=[
      equals "device_id" "$device1["id"]",
    ]
    expect-equals 1 device1-events.size

    // Anon can't see the events.
    device1-events = client-anon.rest.select "events" --filters=[
      equals "device_id" "$device1["id"]",
    ]
    expect-equals 0 device1-events.size

    // Client4 can't see the events of device1.
    device1-events = client4.rest.select "events" --filters=[
      equals "device_id" "$device1["id"]",
    ]
    expect-equals 0 device1-events.size

    // Make sure the email-for-id RPC has the correct permissions.
    // Users can see the email of all users they share an org with.
    rpc-response := client1.rest.rpc "email_for_id" {
      "_id": user-id1,
    }
    expect-equals email1 rpc-response

    rpc-response = client1.rest.rpc "email_for_id" {
      "_id": user-id2,
    }
    expect-equals email2 rpc-response

    rpc-response = client1.rest.rpc "email_for_id" {
      "_id": user-id3,
    }
    expect-equals email3 rpc-response

    // Client1 and client4 are not in the same org.
    rpc-response = client1.rest.rpc "email_for_id" {
      "_id": user-id4,
    }
    expect-null rpc-response

    // Anon can't see any emails.
    rpc-response = client-anon.rest.rpc "email_for_id" {
      "_id": user-id1,
    }
    expect-null rpc-response

    rpc-response = client-anon.rest.rpc "email_for_id" {
      "_id": user-id2,
    }
    expect-null rpc-response

    // Client 3 can remove itself from the org, even though it
    // is not an admin.
    client3.rest.delete "roles" --filters=[
      equals "organization_id" "$organization-id",
      equals "user_id" "$user-id3",
    ]

    /****************************************************************
    organization_id:
      client1 is admin.
      client2 is admin.

    organization3_id:
      client3 is admin.
    ****************************************************************/

    roles1 := client1.rest.select "roles"
    expect-equals 2 roles1.size


expect-throws --contains/string [block]:
  exception := catch: block.call
  expect-not-null exception
  expect (exception.contains contains)
