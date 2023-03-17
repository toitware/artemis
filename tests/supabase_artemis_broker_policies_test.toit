// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server_config as cli_server_config
import artemis.shared.server_config show ServerConfigSupabase
import expect show *
import log
import supabase
import .broker
import .supabase_broker_policies_shared
import .utils

main:
  with_broker --type="supabase-local-artemis" --logger=log.default: | broker/TestBroker |
    server_config := broker.server_config as ServerConfigSupabase
    client_anon := supabase.Client --server_config=server_config --certificate_provider=:unreachable
    client1 := supabase.Client --server_config=server_config --certificate_provider=:unreachable

    email := "$(random)@toit.io"
    password := "password"
    client1.auth.sign_up --email=email --password=password
    // On local setups, the sign up does not need to be confirmed.
    client1.auth.sign_in --email=email --password=password

    // Create a new organization.
    organization := client1.rest.insert "organizations" {
      "name": "Test organization",
    }
    organization_id := organization["id"]

    // Add the devices into the Artemis database.
    device1 := client1.rest.insert "devices" {
      "organization_id": organization_id,
    }
    device_id1 := device1["alias"]
    device2 := client1.rest.insert "devices" {
      "organization_id": organization_id,
    }
    device_id2 := device2["alias"]
    device3 := client1.rest.insert "devices" {
      "organization_id": organization_id,
    }
    device_id3 := device3["alias"]

    run_shared_test
        --client1=client1
        --client_anon=client_anon
        --organization_id=organization_id
        --device_id1=device_id1
        --device_id2=device_id2

    // We can't add a device to an organization if it's not in the public
    // devices table.

    non_existent := random_uuid_string

    expect_throws --contains="row-level security":
      client1.rest.rpc "toit_artemis.new_provisioned" {
        "_device_id": non_existent,
        "_state": { "created": "by user1"},
      }

    client2 := supabase.Client --server_config=server_config
        --certificate_provider=:unreachable
    email2 := "$(random)@toit.io"
    client2.auth.sign_up --email=email2 --password=password
    client2.auth.sign_in --email=email2 --password=password
    client_id2 := (client2.rest.select "profiles")[0]["id"]

    // Add client2 to the same org as client1.
    client1.rest.insert "roles" {
      "organization_id": organization_id,
      "user_id": client_id2,
      "role": "member",
    }

    email3 := "$(random)@toit.io"
    client3 := supabase.Client --server_config=server_config
        --certificate_provider=:unreachable
    client3.auth.sign_up --email=email3 --password=password
    client3.auth.sign_in --email=email3 --password=password

    // client3 can't provision id3 since they aren't in the same organization.
    expect_throws --contains="row-level security":
      client3.rest.rpc "toit_artemis.new_provisioned" {
        "_device_id": device_id3,
        "_state": { "created": "by user3"},
      }

    // client2 can provision id3 since they are in the same organization.
    client2.rest.rpc "toit_artemis.new_provisioned" {
      "_device_id": device_id3,
      "_state": { "created": "by user2"},
    }

    organization3 := client3.rest.insert "organizations" {
      "name": "Test organization 3",
    }
    organization_id3 := organization3["id"]

    // Client1 and client2 can use storage in bucket/org-id, but client3 can't.
    path_org1 := "$ASSETS_BUCKET/$organization_id"
    client1.storage.upload
        --path="$path_org1/foo.txt"
        --content="foo".to_byte_array
    expect_equals "foo".to_byte_array
        client1.storage.download --path="$path_org1/foo.txt"
    expect_equals "foo".to_byte_array
        client2.storage.download --path="$path_org1/foo.txt"

    expect_throws --contains="Not found":
        client3.storage.download --path="$path_org1/foo.txt"

    // Client3 has access to its own org bucket/path.
    path_org3 := "$ASSETS_BUCKET/$organization_id3"
    client3.storage.upload
        --path="$path_org3/bar.txt"
        --content="bar".to_byte_array
    expect_equals "bar".to_byte_array
        client3.storage.download --path="$path_org3/bar.txt"

    expect_throws --contains="Not found":
        client1.storage.download --path="$path_org3/bar.txt"

    // Remember: device_id3 is in the same org as client1 and client2 (organization_id).
    // client3 is in a different org.
    // client1 and client2 can access device_id3, but client3 can't.

    // Report a state and an event for device3.
    // The "update_state" function is available to anonymous users.
    // They need to know an existing device ID.
    client_anon.rest.rpc "toit_artemis.update_state" {
      "_device_id": device_id3,
      "_state": { "updated": "by anon" },
    }

    // Client1 and client2 can access device_id3, but client3 can't.
    [client1, client2].do: | client/supabase.Client |
      state := client1.rest.rpc "toit_artemis.get_state" {
        "_device_id": device_id3,
      }
      expect_equals "by anon" state["updated"]

    // Client3 can't access device_id3.
    state := client3.rest.rpc "toit_artemis.get_state" {
        "_device_id": device_id3,
      }
    expect_null state

    client_anon.rest.rpc "toit_artemis.report_event" {
      "_device_id": device_id3,
      "_type": "test-artemis",
      "_data": { "updated": "by anon" },
    }

    [client1, client2].do: | client/supabase.Client |
      events := client.rest.rpc "toit_artemis.get_events" {
        "_device_ids": [device_id3],
        "_type": "test-artemis",
        "_limit": 1
      }
      expect_equals 1 events.size
      expect_equals device_id3 events[0]["device_id"]
      expect_equals "by anon" events[0]["data"]["updated"]

    // Client3 can't access device_id3.
    events := client3.rest.rpc "toit_artemis.get_events" {
        "_device_ids": [device_id3],
        "_type": "test-artemis",
        "_limit": 1
      }
    expect events.is_empty
