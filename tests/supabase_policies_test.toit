// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server_config as cli_server_config
import artemis.shared.server_config show ServerConfigSupabase
import expect show *
import supabase
import .utils

main:
  with_test_cli
      --artemis_type="supabase"
      --broker_type="supabase"
      --no-start_device_artemis
      : | test_cli/TestCli _ |

        config := test_cli.config
        artemis_broker := (cli_server_config.get_server_from_config config null cli.CONFIG_ARTEMIS_DEFAULT_KEY) as ServerConfigSupabase

        client_anon := supabase.Client --server_config=artemis_broker --certificate_provider=:unreachable
        client1 := supabase.Client --server_config=artemis_broker --certificate_provider=:unreachable
        client2 := supabase.Client --server_config=artemis_broker --certificate_provider=:unreachable
        client3 := supabase.Client --server_config=artemis_broker --certificate_provider=:unreachable
        client4 := supabase.Client --server_config=artemis_broker --certificate_provider=:unreachable

        [ client1, client2, client3, client4 ].do:
          email := "$(random)@toit.io"
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

        users2 := client2.rest.select "profiles"
        expect_equals 1 users2.size
        user2 := users2[0]
        user_id2 := user2["id"]
        name2 := user2["name"]

        users3 := client3.rest.select "profiles"
        expect_equals 1 users3.size
        user3 := users3[0]
        user_id3 := user3["id"]
        name3 := user3["name"]

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

        // Users can't change other profiles.
        expect_throws --contains="404": client2.rest.update "profiles" --filters=[
          "id=eq.$user_id1",
        ] {
          "name": "$name1 + NOPE",
        }
        users1 = client1.rest.select "profiles" --filters=[
          "id=eq.$user_id1",
        ]
        expect_equals 1 users1.size
        expect_equals "$name1 + changed" users1[0]["name"]

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

        // Both, client1 and client2, can insert devices.
        device1 := client1.rest.insert "devices" {
          "organization_id": organization_id,
        }
        device2 := client2.rest.insert "devices" {
          "organization_id": organization_id,
        }

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

        // Client2 can now add a new member to the org.
        client2.rest.insert "roles" {
          "organization_id": organization_id,
          "user_id": user_id3,
          "role": "member",
        }

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

expect_throws --contains/string [block]:
  exception := catch: block.call
  expect_not_null exception
  expect (exception.contains contains)
