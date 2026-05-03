// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server-config as cli-server-config
import artemis.shared.server-config show ServerConfigSupabase
import expect show *
import log
import supabase
import .broker
import .supabase-broker-policies-shared
import .utils

main args:
  with-broker --args=args --type="supabase-local-artemis" --logger=log.default: | broker/TestBroker |
    server-config := broker.server-config as ServerConfigSupabase
    client-anon := supabase.Client --server-config=server-config
    client1 := supabase.Client --server-config=server-config

    email := "$(random)@toit.io"
    password := "password"
    client1.auth.sign-up --email=email --password=password
    // On local setups, the sign up does not need to be confirmed.
    client1.auth.sign-in --email=email --password=password

    // Create a new organization.
    organization := client1.rest.insert "organizations" {
      "name": "Test organization",
    }
    organization-id := organization["id"]

    // Add the devices into the Artemis database.
    device1 := client1.rest.insert "devices" {
      "organization_id": organization-id,
    }
    device-id1 := device1["alias"]
    device2 := client1.rest.insert "devices" {
      "organization_id": organization-id,
    }
    device-id2 := device2["alias"]
    device3 := client1.rest.insert "devices" {
      "organization_id": organization-id,
    }
    device-id3 := device3["alias"]

    run-shared-test
        --client1=client1
        --client-anon=client-anon
        --organization-id=organization-id
        --device-id1=device-id1
        --device-id2=device-id2

    // We can't add a device to an organization if it's not in the public
    // devices table.

    non-existent := random-uuid

    expect-throws --contains="row-level security":
      client1.rest.rpc --schema="toit_artemis" "new_provisioned" {
        "_device_id": "$non-existent",
        "_state": { "created": "by user1"},
      }

    client2 := supabase.Client --server-config=server-config
    email2 := "$(random)@toit.io"
    client2.auth.sign-up --email=email2 --password=password
    client2.auth.sign-in --email=email2 --password=password
    client-id2 := (client2.rest.select "profiles")[0]["id"]

    // Add client2 to the same org as client1.
    client1.rest.insert "roles" {
      "organization_id": organization-id,
      "user_id": client-id2,
      "role": "member",
    }

    email3 := "$(random)@toit.io"
    client3 := supabase.Client --server-config=server-config
    client3.auth.sign-up --email=email3 --password=password
    client3.auth.sign-in --email=email3 --password=password

    // Client3 is not in the same org as client1 and client2.
    run-shared-pod-description-test
        --client1=client1
        --organization-id=organization-id
        --other-clients=[client-anon, client3]

    // client3 can't provision id3 since they aren't in the same organization.
    expect-throws --contains="row-level security":
      client3.rest.rpc --schema="toit_artemis" "new_provisioned" {
        "_device_id": device-id3,
        "_state": { "created": "by user3"},
      }

    // client2 can provision id3 since they are in the same organization.
    client2.rest.rpc --schema="toit_artemis" "new_provisioned" {
      "_device_id": device-id3,
      "_state": { "created": "by user2"},
    }

    organization3 := client3.rest.insert "organizations" {
      "name": "Test organization 3",
    }
    organization-id3 := organization3["id"]

    2.repeat:
      bucket := it == 0 ? ASSETS-BUCKET : PODS-BUCKET
      // Client1 and client2 can use storage in bucket/org-id, but client3 can't.
      path-org1 := "$bucket/$organization-id"
      client1.storage.upload
          --path="$path-org1/foo.txt"
          --content="foo".to-byte-array
      expect-equals "foo".to-byte-array
          client1.storage.download --path="$path-org1/foo.txt"
      expect-equals "foo".to-byte-array
          client2.storage.download --path="$path-org1/foo.txt"

      if bucket == ASSETS-BUCKET:
        // Assets are public.
        expect-equals "foo".to-byte-array
            client3.storage.download --path="$path-org1/foo.txt"
      else:
        expect-throws --contains="Not found":
            client3.storage.download --path="$path-org1/foo.txt"

      // Client3 has access to its own org bucket/path.
      path-org3 := "$bucket/$organization-id3"
      client3.storage.upload
          --path="$path-org3/bar.txt"
          --content="bar".to-byte-array
      expect-equals "bar".to-byte-array
          client3.storage.download --path="$path-org3/bar.txt"

      if bucket == ASSETS-BUCKET:
        // Assets are public.
        expect-equals "bar".to-byte-array
            client1.storage.download --path="$path-org3/bar.txt"
      else:
        expect-throws --contains="Not found":
            client1.storage.download --path="$path-org3/bar.txt"

    // Remember: device_id3 is in the same org as client1 and client2 (organization_id).
    // client3 is in a different org.
    // client1 and client2 can access device_id3, but client3 can't.

    // Report a state and an event for device3.
    // The "update_state" function is available to anonymous users.
    // They need to know an existing device ID.
    client-anon.rest.rpc --schema="toit_artemis" "update_state" {
      "_device_id": device-id3,
      "_state": { "updated": "by anon" },
    }

    // Client1 and client2 can access device_id3, but client3 can't.
    [client1, client2].do: | client/supabase.Client |
      state := client1.rest.rpc --schema="toit_artemis" "get_state" {
        "_device_id": device-id3,
      }
      expect-equals "by anon" state["updated"]

    // Client3 can't access device_id3.
    state := client3.rest.rpc --schema="toit_artemis" "get_state" {
        "_device_id": device-id3,
      }
    expect-null state

    client-anon.rest.rpc --schema="toit_artemis" "report_event" {
      "_device_id": device-id3,
      "_type": "test-artemis",
      "_data": { "updated": "by anon" },
    }

    [client1, client2].do: | client/supabase.Client |
      events := client.rest.rpc --schema="toit_artemis" "get_events" {
        "_device_ids": [device-id3],
        "_types": ["test-artemis"],
        "_limit": 1
      }
      expect-equals 1 events.size
      expect-equals device-id3 events[0]["device_id"]
      expect-equals "by anon" events[0]["data"]["updated"]

    // Client3 can't access device_id3.
    events := client3.rest.rpc --schema="toit_artemis" "get_events" {
        "_device_ids": [device-id3],
        "_types": ["test-artemis"],
        "_limit": 1
      }
    expect events.is-empty
