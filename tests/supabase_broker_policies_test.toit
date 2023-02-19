// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server_config as cli_server_config
import artemis.shared.server_config show ServerConfigSupabase
import expect show *
import log
import supabase
import uuid
import .broker

main:
  with_broker --type="supabase" --logger=log.default: | broker/TestBroker |
    server_config := broker.server_config as ServerConfigSupabase
    client_anon := supabase.Client --server_config=server_config --certificate_provider=:unreachable
    client1 := supabase.Client --server_config=server_config --certificate_provider=:unreachable

    email := "$(random)@toit.io"
    password := "password"
    client1.auth.sign_up --email=email --password=password
    // On local setups, the sign up does not need to be confirmed.
    client1.auth.sign_in --email=email --password=password

    some_id ::= (uuid.uuid5 "some" "id $random $Time.now").stringify
    some_id2 ::= (uuid.uuid5 "some" "id $random $Time.now").stringify

    // We only need to worry about the functions that have been copied to the public schema.
    // The tables themselves are inaccessible from the public PostgREST.
    // Each user should only be able to see their own profile.

    // The "toit_artemis.new_provisioned" function is only accessible to
    // authenticated users.
    expect_throws --contains="row-level security":
      client_anon.rest.rpc "toit_artemis.new_provisioned" {
        "_device_id": some_id,
        "_state": {:},
      }

    client1.rest.rpc "toit_artemis.new_provisioned" {
      "_device_id": some_id,
      "_state": { "created": "by user1" },
    }

    // The device is now available to the authenticated client.
    state := client1.rest.rpc "toit_artemis.get_state" {
      "_device_id": some_id,
    }
    expect_equals "by user1" state["created"]

    // Provisioning a device twice should fail.
    expect_throws --contains="duplicate key":
      client1.rest.rpc "toit_artemis.new_provisioned" {
        "_device_id": some_id,
        "_state": {:},
      }

    // The "update_state" function is available to anonymous users.
    // They need to know an existing device ID.
    client_anon.rest.rpc "toit_artemis.update_state" {
      "_device_id": some_id,
      "_state": { "updated": "by anon" },
    }

    // Doesn't throw, but doesn't do anything.
    client_anon.rest.rpc "toit_artemis.update_state" {
      "_device_id": some_id2,
      "_state": { "updated": "by anon" },
    }

    // The "get_state" function is only available to authenticated users.
    state = client1.rest.rpc "toit_artemis.get_state" {
      "_device_id": some_id,
    }
    expect_equals "by anon" state["updated"]

    state = client1.rest.rpc "toit_artemis.get_state" {
      "_device_id": some_id2,
    }
    expect_null state

    state = client_anon.rest.rpc "toit_artemis.get_state" {
      "_device_id": some_id,
    }
    expect_null state

    // The "get_goal" function is available to anonymous users.
    // They need to know an existing device ID.
    goal := client_anon.rest.rpc "toit_artemis.get_goal" {
      "_device_id": some_id,
    }
    expect_null goal  // Hasn't been set yet.

    // The "set_goal" function is only available to authenticated users.
    expect_throws --contains="row-level security":
      client_anon.rest.rpc "toit_artemis.set_goal" {
        "_device_id": some_id,
        "_goal": { "updated": "by anon" },
      }

    client1.rest.rpc "toit_artemis.set_goal" {
      "_device_id": some_id,
      "_goal": { "updated": "by user1" },
    }

    // The goal is now available to the anon client.
    goal = client_anon.rest.rpc "toit_artemis.get_goal" {
      "_device_id": some_id,
    }
    expect_equals "by user1" goal["updated"]

    // Only authenticated can remove devices.
    client_anon.rest.rpc "toit_artemis.remove_device" {
      "_device_id": some_id,
    }
    // The device is still there:
    state = client1.rest.rpc "toit_artemis.get_state" {
      "_device_id": some_id,
    }
    expect_equals "by anon" state["updated"]

    client1.rest.rpc "toit_artemis.remove_device" {
      "_device_id": some_id,
    }

    // The device is now gone.
    state = client1.rest.rpc "toit_artemis.get_state" {
      "_device_id": some_id,
    }
    expect_null state

    ASSETS_BUCKET := "toit-artemis-assets"

    storage_id := (uuid.uuid5 "storage" "id $random $Time.now").stringify

    // Authenticated can write to the storage.
    // All other users (including anon) can only see it.
    client1.storage.upload
        --path="$ASSETS_BUCKET/$storage_id"
        --content="test".to_byte_array

    // Check that anon can see it with public download.
    expect_equals "test".to_byte_array
        client_anon.storage.download --public --path="$ASSETS_BUCKET/$storage_id"

    // Anon doesn't see it with regular download.
    expect_throws --contains="Not found":
        client_anon.storage.download --path="$ASSETS_BUCKET/$storage_id"

    // Check that anon can't update it.
    expect_throws --contains="row-level security":
      client_anon.storage.upload
          --path="$ASSETS_BUCKET/$storage_id"
          --content="bad".to_byte_array

    // Check that it's still the same.
    expect_equals "test".to_byte_array
        client_anon.storage.download --public --path="$ASSETS_BUCKET/$storage_id"

    storage_id2 := (uuid.uuid5 "storage" "id $random $Time.now").stringify
    // Check that anon can't write to it.
    expect_throws --contains="row-level security":
        client_anon.storage.upload
            --path="$ASSETS_BUCKET/$storage_id2"
            --content="test".to_byte_array

expect_throws --contains/string [block]:
  exception := catch:
    block.call
    print "Expected exception, but none was thrown."
    expect false
  expect (exception.contains contains)
