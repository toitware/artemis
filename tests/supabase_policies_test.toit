// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server_config as cli_server_config
import artemis.shared.server_config show ServerConfigSupabase
import expect show *
import supabase
import uuid
import .artemis_server

main:
  with_artemis_server --type="supabase": | artemis_server/TestArtemisServer |
    server_config := artemis_server.server_config as ServerConfigSupabase
    client_anon := supabase.Client --server_config=server_config --certificate_provider=:unreachable
    client1 := supabase.Client --server_config=server_config --certificate_provider=:unreachable
    client2 := supabase.Client --server_config=server_config --certificate_provider=:unreachable
    client3 := supabase.Client --server_config=server_config --certificate_provider=:unreachable
    client4 := supabase.Client --server_config=server_config --certificate_provider=:unreachable

    emails := []
    [ client1, client2, client3, client4 ].do:
      email := "$(random)@toit.io"
      emails.add email
      password := "password"
      it.auth.sign_up --email=email --password=password
      // On local setups, the sign up does not need to be confirmed.
      it.auth.sign_in --email=email --password=password

    // Each user should only be able to see their own profile.
    users1 := client1.rest.select "profiles"
    expect_equals 1 users1.size
    user1 := users1[0]
    user_id1 := user1["id"]
    name1 := user1["name"]
    email1 := emails[0]
    users1_with_email := client1.rest.select "profiles_with_email"
    expect_equals 1 users1.size
    user1_with_email := users1_with_email[0]
    expect_equals user_id1 user1_with_email["id"]
    expect_equals name1 user1_with_email["name"]
    expect_equals email1 user1_with_email["email"]

    users2 := client2.rest.select "profiles"
    expect_equals 1 users2.size
    user2 := users2[0]
    user_id2 := user2["id"]
    name2 := user2["name"]
    email2 := emails[1]
    users2_with_email := client2.rest.select "profiles_with_email"
    expect_equals 1 users2.size
    user2_with_email := users2_with_email[0]
    expect_equals user_id2 user2_with_email["id"]
    expect_equals name2 user2_with_email["name"]
    expect_equals email2 user2_with_email["email"]

    users3 := client3.rest.select "profiles"
    expect_equals 1 users3.size
    user3 := users3[0]
    user_id3 := user3["id"]
    name3 := user3["name"]
    email3 := emails[2]
    users3_with_email := client3.rest.select "profiles_with_email"
    expect_equals 1 users3.size
    user3_with_email := users3_with_email[0]
    expect_equals user_id3 user3_with_email["id"]
    expect_equals name3 user3_with_email["name"]
    expect_equals email3 user3_with_email["email"]

    users4 := client4.rest.select "profiles"
    expect_equals 1 users4.size
    user4 := users4[0]
    user_id4 := user4["id"]
    name4 := user4["name"]
    email4 := emails[3]
    users4_with_email := client4.rest.select "profiles_with_email"
    expect_equals 1 users4.size
    user4_with_email := users4_with_email[0]
    expect_equals user_id4 user4_with_email["id"]
    expect_equals name4 user4_with_email["name"]
    expect_equals email4 user4_with_email["email"]

    // Anon should not be able to see any profile.
    users_anon := client_anon.rest.select "profiles"
    expect_equals 0 users_anon.size

    // Users can change their profile.
    client1.rest.update "profiles" --filters=[
      "id=eq.$user_id1",
    ] {
      "name": "$name1 + changed",
    }

    // Check the new name.
    users1 = client1.rest.select "profiles" --filters=[
      "id=eq.$user_id1",
    ]
    expect_equals 1 users1.size
    expect_equals "$name1 + changed" users1[0]["name"]

    // We don't give any way to change the email with the profile-with-email view.
    expect_throws --contains="cannot update":
      client1.rest.update "profiles_with_email" --filters=[
        "id=eq.$user_id1",
      ] {
        "email": "doesnt@work",
      }
    // The update didn't succeed.
    users1 = client1.rest.select "profiles_with_email" --filters=[
      "id=eq.$user_id1",
    ]
    expect_equals 1 users1.size
    expect_equals email1 users1[0]["email"]

    // We can't change the profile of a different user through the profile-with-email view.
    client1.rest.update "profiles_with_email" --filters=[
      "id=eq.$user_id2",
    ] {
      "name": "$name2 + won't change",
    }
    // The name is still the same.
    users2 = client2.rest.select "profiles_with_email" --filters=[
      "id=eq.$user_id2",
    ]
    expect_equals 1 users2.size
    expect_equals name2 users2[0]["name"]

    // Users can't change other profiles.
    // In fact, they can't even see them for update, which means that the
    // update here will succeed (the filter will find no matching
    // row, and thus not try to change anything).
    client2.rest.update "profiles" --filters=[
      "id=eq.$user_id1",
    ] {
      "name": "$name1 + NOPE",
    }
    users1 = client1.rest.select "profiles" --filters=[
      "id=eq.$user_id1",
    ]
    expect_equals 1 users1.size
    expect_equals "$name1 + changed" users1[0]["name"]

    // The same is true for the profiles_with_email view, which
    // is based on the profiles table.
    client2.rest.update "profiles_with_email" --filters=[
      "id=eq.$user_id1",
    ] {
      "name": "$name1 + NOPE",
    }

    // Create a new organization.
    organization := client1.rest.insert "organizations" {
      "name": "Test organization",
    }

    organization_id := organization["id"]

    // There should be an automatic 'admin' role for the user that
    // created the organization.
    roles := client1.rest.select "roles"
    expect_equals 1 roles.size
    role := roles[0]
    expect_equals "admin" role["role"]
    expect_equals organization_id role["organization_id"]
    expect_equals user_id1 role["user_id"]

    // The other clients should not be able to see the organization yet.
    organizations2 := client2.rest.select "organizations"
    expect_equals 0 organizations2.size

    // The anon client should not be able to see the organization.
    organizations_anon := client_anon.rest.select "organizations"
    expect_equals 0 organizations_anon.size

    // Admin can change the organization.
    // Using 'upsert' as 'update' hasn't been implemented at the time of
    // writing the test.
    client1.rest.upsert "organizations" {
      "id": organization_id,
      "name": "New name",
    }

    // Check the new name.
    organizations := client1.rest.select "organizations" --filters=[
      "id=eq.$organization_id",
    ]
    expect_equals 1 organizations.size
    expect_equals "New name" organizations[0]["name"]

    expect_throws --contains="policy": client2.rest.upsert "organizations" {
      "id": organization_id,
      "name": "New name client2",
    }

    // Anon can't change organization either.
    expect_throws --contains="policy": client_anon.rest.upsert "organizations" {
      "id": organization_id,
      "name": "New name anon",
    }

    // Make client2 a member.
    client1.rest.insert "roles" {
      "organization_id": organization_id,
      "user_id": user_id2,
      "role": "member",
    }

    /****************************************************************
    organization_id:
      client1 is admin.
      client2 is member.
    ****************************************************************/

    // There are now two members in the org:
    roles = client1.rest.select "roles"
    expect_equals 2 roles.size

    // Client2 can now see the organization.
    organizations2 = client2.rest.select "organizations"
    expect_equals 1 organizations2.size
    expect_equals organization_id organizations2[0]["id"]

    // Client2 can't change the organization.
    expect_throws --contains="policy": client2.rest.upsert "organizations" {
      "id": organization_id,
      "name": "New name client2",
    }

    // Client2 can't promote themself to admin.
    expect_throws --contains="policy": client2.rest.upsert "roles" {
      "organization_id": organization_id,
      "user_id": user_id2,
      "role": "admin",
    }

    // Client2 can't add a new member to the org.
    expect_throws --contains="policy": client2.rest.insert "roles" {
      "organization_id": organization_id,
      "user_id": user_id3,
      "role": "member",
    }

    // Both, client1 and client2 can now see the profiles of the other.
    users1 = client1.rest.select "profiles"
    expect_equals 2 users1.size
    expect (users1.any: it["id"] == user_id1)
    expect (users1.any: it["id"] == user_id2)

    users2 = client2.rest.select "profiles"
    expect_equals 2 users2.size
    expect (users2.any: it["id"] == user_id1)
    expect (users2.any: it["id"] == user_id2)

    // Both, client1 and client2, can insert devices.
    device1 := client1.rest.insert "devices" {
      "organization_id": organization_id,
    }
    device2 := client2.rest.insert "devices" {
      "organization_id": organization_id,
    }

    // Neither can update the profile of the other.
    client2.rest.update "profiles" --filters=[
      "id=eq.$user_id1",
    ] {
      "name": "$name1 + NOPE",
    }
    users1 = client1.rest.select "profiles" --filters=[
      "id=eq.$user_id1",
    ]
    expect users1[0]["name"] != "$name1 + NOPE"

    // Both can see the new devices.
    devices1 := client1.rest.select "devices" --filters=[
      "organization_id=eq.$organization_id",
    ]
    expect_equals 2 devices1.size

    devices2 := client2.rest.select "devices" --filters=[
      "organization_id=eq.$organization_id",
    ]
    expect_equals 2 devices2.size

    [device1, device2].do: |device|
      expect (devices1.any: it["id"] == device["id"])
      expect (devices2.any: it["id"] == device["id"])

    // Client3 and anon can't see the devices.
    devices3 := client3.rest.select "devices"
    expect_equals 0 devices3.size

    devices_anon := client_anon.rest.select "devices"
    expect_equals 0 devices_anon.size

    // Client3 can't insert a device.
    expect_throws --contains="policy": client3.rest.insert "devices" {
      "organization_id": organization_id,
    }

    // Anon can't insert a device.
    expect_throws --contains="policy": client_anon.rest.insert "devices" {
      "organization_id": organization_id,
    }

    // Make client2 an admin.
    client1.rest.update "roles" --filters=[
      "organization_id=eq.$organization_id",
      "user_id=eq.$user_id2",
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
      "organization_id": organization_id,
      "user_id": user_id3,
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
    expect_equals 3 roles3.size

    // Client3 can now see the devices.
    devices3 = client3.rest.select "devices"
    expect_equals 2 devices3.size

    // Client3 can now insert a device.
    device3 := client3.rest.insert "devices" {
      "organization_id": organization_id,
    }

    // Client3 can now see the new device.
    devices3 = client3.rest.select "devices" --filters=[
      "id=eq.$device3["id"]",
    ]
    expect_equals 1 devices3.size

    // Users can be in multiple organizations.

    // User3 can create an organization that they are the admin of.
    organization3 := client3.rest.insert "organizations" {
      "name": "Organization 2",
    }
    organization3_id := organization3["id"]

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
    expect_equals 2 organizations3.size

    // User3 can see the new organization in the roles table.
    roles3 = client3.rest.select "roles"
    expect_equals 4 roles3.size

    // Client1, client2 and anon don't see the new organization.
    organizations1 := client1.rest.select "organizations"
    expect_equals 1 organizations1.size

    organizations2 = client2.rest.select "organizations"
    expect_equals 1 organizations2.size

    organizations_anon = client_anon.rest.select "organizations"
    expect_equals 0 organizations_anon.size

    // Client3 is admin of their organization, but not of the other one.
    expect_throws --contains="policy": client3.rest.upsert "organizations" {
      "id": organization_id,
      "name": "New name client3",
    }

    client3.rest.upsert "organizations" {
      "id": organization3_id,
      "name": "New name client3",
    }

    organizations3 = client3.rest.select "organizations" --filters=[
      "id=eq.$organization3_id",
    ]
    expect_equals "New name client3" organizations3[0]["name"]

    // Members can see the events of their devices.
    device1_events := client1.rest.select "events" --filters=[
      "device_id=eq.$device1["id"]",
    ]
    expect_equals 0 device1_events.size

    // Anon can insert into events, as long as the device_id is valid.
    // Note that we have to use the --no-return_inserted flag, because
    // anon can't see the inserted event.
    client_anon.rest.insert "events" --no-return_inserted {
      "device_id": device1["id"],
      "data": { "type": "test"},
    }

    // Now we have one event.
    device1_events = client1.rest.select "events" --filters=[
      "device_id=eq.$device1["id"]",
    ]
    expect_equals 1 device1_events.size

    // Anon can't see the events.
    device1_events = client_anon.rest.select "events" --filters=[
      "device_id=eq.$device1["id"]",
    ]
    expect_equals 0 device1_events.size

    // Client4 can't see the events of device1.
    device1_events = client4.rest.select "events" --filters=[
      "device_id=eq.$device1["id"]",
    ]
    expect_equals 0 device1_events.size

    // Make sure the email-for-id RPC has the correct permissions.
    // Users can see the email of all users they share an org with.
    rpc_response := client1.rest.rpc "email_for_id" {
      "_id": user_id1,
    }
    expect_equals email1 rpc_response

    rpc_response = client1.rest.rpc "email_for_id" {
      "_id": user_id2,
    }
    expect_equals email2 rpc_response

    rpc_response = client1.rest.rpc "email_for_id" {
      "_id": user_id3,
    }
    expect_equals email3 rpc_response

    // Client1 and client4 are not in the same org.
    rpc_response = client1.rest.rpc "email_for_id" {
      "_id": user_id4,
    }
    expect_null rpc_response

    // Anon can't see any emails.
    rpc_response = client_anon.rest.rpc "email_for_id" {
      "_id": user_id1,
    }
    expect_null rpc_response

    rpc_response = client_anon.rest.rpc "email_for_id" {
      "_id": user_id2,
    }
    expect_null rpc_response

    // Client 3 can remove itself from the org, even though it
    // is not an admin.
    client3.rest.delete "roles" --filters=[
      "organization_id=eq.$organization_id",
      "user_id=eq.$user_id3",
    ]

    /****************************************************************
    organization_id:
      client1 is admin.
      client2 is admin.

    organization3_id:
      client3 is admin.
    ****************************************************************/

    roles1 := client1.rest.select "roles"
    expect_equals 2 roles1.size

    client_admin := supabase.Client --server_config=server_config --certificate_provider=:unreachable
    client_admin.auth.sign_in
        --email="test-admin@toit.io"
        --password="password"

    // Admins can change the sdk table.
    // All other users (including auth) can only see it.

    // Clear the sdk table for simplicity.
    // Delete requires a where clause, so we use a filter that is always true.
    client_admin.rest.delete "sdks" --filters=["id=gte.0"]
    sdks := client_admin.rest.select "sdks"
    expect_equals 0 sdks.size

    // Admin can insert.
    sdk := client_admin.rest.insert "sdks" {
      "version": "v1.0.0",
    }
    expect_equals "v1.0.0" sdk["version"]
    sdkv1_id := sdk["id"]

    // Only one entry per version is allowed in the table.
    expect_throws --contains="unique": client_admin.rest.insert "sdks" {
      "version": "v1.0.0",
    }

    // Check that auth and anon can see it.
    sdks = client_anon.rest.select "sdks"
    expect_equals 1 sdks.size
    expect_equals "v1.0.0" sdks[0]["version"]

    sdks = client1.rest.select "sdks"
    expect_equals 1 sdks.size
    expect_equals "v1.0.0" sdks[0]["version"]

    // Neither anon, nor auth can insert.
    expect_throws --contains="policy": client_anon.rest.insert "sdks" {
      "version": "v2.0.0",
    }
    expect_throws --contains="policy": client1.rest.insert "sdks" {
      "version": "v2.0.0",
    }

    // Same is true for artemis services.
    // Admins can change the sdk table.
    // All other users (including auth) can only see it.

    // Clear the sdk table for simplicity.
    // Delete requires a where clause, so we use a filter that is always true.
    client_admin.rest.delete "artemis_services" --filters=["id=gte.0"]
    artemis_services := client_admin.rest.select "artemis_services"
    expect_equals 0 artemis_services.size

    // Admin can insert.
    services := client_admin.rest.insert "artemis_services" {
      "version": "v9.8.7",
    }
    expect_equals "v9.8.7" services["version"]
    service1_id := services["id"]

    // Only one entry per version is allowed in the table.
    expect_throws --contains="unique": client_admin.rest.insert "artemis_services" {
      "version": "v9.8.7",
    }

    // Check that auth and anon can see it.
    artemis_services = client_anon.rest.select "artemis_services"
    expect_equals 1 artemis_services.size
    expect_equals "v9.8.7" artemis_services[0]["version"]

    artemis_services = client1.rest.select "artemis_services"
    expect_equals 1 artemis_services.size
    expect_equals "v9.8.7" artemis_services[0]["version"]

    // Neither anon, nor auth can insert.
    expect_throws --contains="policy": client_anon.rest.insert "artemis_services" {
      "version": "2.0.0",
    }
    expect_throws --contains="policy": client1.rest.insert "artemis_services" {
      "version": "2.0.0",
    }

    // Same is true for images.
    // Admins can change the sdk table.
    // All other users (including auth) can only see it.

    // Clear the table for simplicity.
    // Delete requires a where clause, so we use a filter that is always true.
    client_admin.rest.delete "service_images" --filters=["id=gte.0"]
    images := client_admin.rest.select "service_images"
    expect_equals 0 images.size

    image := "test-$(random).image"

    // Admin can insert.
    service_snapshot := client_admin.rest.insert "service_images" {
      "sdk_id": sdkv1_id,
      "service_id": service1_id,
      "image": image,
    }
    expect_equals sdkv1_id service_snapshot["sdk_id"]
    expect_equals service1_id service_snapshot["service_id"]
    expect_equals image service_snapshot["image"]
    service_snapshot_id := service_snapshot["id"]

    // sdk/service pair must be unique.
    expect_throws --contains="unique": client_admin.rest.insert "service_images" {
      "sdk_id": sdkv1_id,
      "service_id": service1_id,
      "image": image,
    }

    // Check that auth and anon can see it.
    images = client_anon.rest.select "service_images"
    expect_equals 1 images.size
    expect_equals sdkv1_id images[0]["sdk_id"]
    expect_equals service1_id service_snapshot["service_id"]
    expect_equals image images[0]["image"]

    images = client1.rest.select "service_images"
    expect_equals 1 images.size
    expect_equals sdkv1_id images[0]["sdk_id"]
    expect_equals service1_id service_snapshot["service_id"]
    expect_equals image images[0]["image"]

    // Create a second SDK entry, so that the following test doesn't
    // hit a unique constraint check.
    services = client_admin.rest.insert "artemis_services" {
      "version": "v9.9.9",
    }
    expect_equals "v9.9.9" services["version"]
    service2_id := services["id"]

    // Neither anon, nor auth can insert.
    expect_throws --contains="policy": client_anon.rest.insert "service_images" {
      "sdk_id": sdkv1_id,
      "service_id": service2_id,
      "image": image,
    }
    expect_throws --contains="policy": client1.rest.insert "service_images" {
      "sdk_id": sdkv1_id,
      "service_id": service2_id,
      "image": image,
    }

    // Admins can write to the storage.
    // All other users (including auth) can only see it.
    BUCKET ::= "service-images"
    client_admin.storage.upload
        --path="$BUCKET/$image"
        --content="test".to_byte_array

    // Check that auth and anon can see it.
    expect_equals "test".to_byte_array
        client_anon.storage.download --path="$BUCKET/$image"
    expect_equals "test".to_byte_array
        client1.storage.download --path="$BUCKET/$image"

expect_throws --contains/string [block]:
  exception := catch: block.call
  expect_not_null exception
  expect (exception.contains contains)
