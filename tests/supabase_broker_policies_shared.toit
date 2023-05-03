// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server_config as cli_server_config
import artemis.shared.server_config show ServerConfigSupabase
import expect show *
import log
import supabase
import uuid
import .broker
import .utils

ASSETS_BUCKET ::= "toit-artemis-assets"

run_shared_test
    --client1/supabase.Client
    --client_anon/supabase.Client
    --organization_id/string="$TEST_ORGANIZATION_UUID"
    --device_id1/string="$random_uuid"
    --device_id2/string="$random_uuid":

  // We only need to worry about the functions that have been copied to the public schema.
  // The tables themselves are inaccessible from the public PostgREST.
  // Each user should only be able to see their own profile.

  // The "toit_artemis.new_provisioned" function is only accessible to
  // authenticated users.
  expect_throws --contains="row-level security":
    client_anon.rest.rpc "toit_artemis.new_provisioned" {
      "_device_id": device_id1,
      "_state": {:},
    }

  client1.rest.rpc "toit_artemis.new_provisioned" {
    "_device_id": device_id1,
    "_state": { "created": "by user1" },
  }

  // The device is now available to the authenticated client.
  state := client1.rest.rpc "toit_artemis.get_state" {
    "_device_id": device_id1,
  }
  expect_equals "by user1" state["created"]

  // Provisioning a device twice should fail.
  expect_throws --contains="duplicate key":
    client1.rest.rpc "toit_artemis.new_provisioned" {
      "_device_id": device_id1,
      "_state": {:},
    }

  // The "update_state" function is available to anonymous users.
  // They need to know an existing device ID.
  client_anon.rest.rpc "toit_artemis.update_state" {
    "_device_id": device_id1,
    "_state": { "updated": "by anon" },
  }

  // If the device id isn't known (no call to new_provisioned) the call fails.
  expect_throws --contains="foreign key":
    client_anon.rest.rpc "toit_artemis.update_state" {
      "_device_id": device_id2,
      "_state": { "updated": "by anon" },
    }

  // The "get_state" function is only available to authenticated users.
  state = client1.rest.rpc "toit_artemis.get_state" {
    "_device_id": device_id1,
  }
  expect_equals "by anon" state["updated"]

  state = client1.rest.rpc "toit_artemis.get_state" {
    "_device_id": device_id2,
  }
  expect_null state

  state = client_anon.rest.rpc "toit_artemis.get_state" {
    "_device_id": device_id1,
  }
  expect_null state

  // report_event is available to devices (and thus anonymous).
  client_anon.rest.rpc "toit_artemis.report_event" {
    "_device_id": device_id1,
    "_type": "test",
    "_data": { "updated": "by anon" },
  }

  // Only ids in the device-list are valid.
  expect_throws --contains="foreign key":
    client_anon.rest.rpc "toit_artemis.report_event" {
      "_device_id": "$random_uuid",
      "_type": "test",
      "_data": { "updated": "by anon" },
    }

  // Anon can't get events.
  events := client_anon.rest.rpc "toit_artemis.get_events" {
      "_device_ids": [device_id1],
      "_types": ["test"],
      "_limit": 1
    }
  expect_equals 0 events.size

  // The events can be retrieved by authenticated users.
  events = client1.rest.rpc "toit_artemis.get_events" {
    "_device_ids": [device_id1],
    "_types": ["test"],
    "_limit": 1
  }
  expect_equals 1 events.size
  row := events[0]
  expect_equals device_id1 row["device_id"]
  expect_equals "by anon" row["data"]["updated"]

  all_events := client1.rest.rpc "toit_artemis.get_events" {
    "_device_ids": [device_id1],
    "_types": [],
    "_limit": 10_000,
  }
  all_events_size := all_events.size

  // The "get_goal" function is available to anonymous users.
  // They need to know an existing device ID.
  goal := client_anon.rest.rpc "toit_artemis.get_goal" {
    "_device_id": device_id1,
  }
  expect_null goal  // Hasn't been set yet.

  all_events = client1.rest.rpc "toit_artemis.get_events" {
    "_device_ids": [device_id1],
    "_types": [],
    "_limit": 10_000,
  }
  expect_equals all_events_size + 1 all_events.size

  // The "set_goal" function is only available to authenticated users.
  expect_throws --contains="row-level security":
    client_anon.rest.rpc "toit_artemis.set_goal" {
      "_device_id": device_id1,
      "_goal": { "updated": "by anon" },
    }

  client1.rest.rpc "toit_artemis.set_goal" {
    "_device_id": device_id1,
    "_goal": { "updated": "by user1" },
  }

  // The goal is now available to the anon client.
  goal = client_anon.rest.rpc "toit_artemis.get_goal" {
    "_device_id": device_id1,
  }
  expect_equals "by user1" goal["updated"]

  all_events = client1.rest.rpc "toit_artemis.get_events" {
    "_device_ids": [device_id1],
    "_types": [],
    "_limit": 10_000,
  }
  all_events_size = all_events.size

  // The get_goal_no_event is only available to the CLI.
  goal = client_anon.rest.rpc "toit_artemis.get_goal_no_event" {
    "_device_id": device_id1,
  }
  expect_null goal

  goal = client1.rest.rpc "toit_artemis.get_goal_no_event" {
    "_device_id": device_id1,
  }
  expect_equals "by user1" goal["updated"]

  // The no-event version doesn't create an event.
  all_events = client1.rest.rpc "toit_artemis.get_events" {
    "_device_ids": [device_id1],
    "_types": [],
    "_limit": 10_000,
  }
  expect_equals all_events_size all_events.size

  // Only authenticated can remove devices.
  client_anon.rest.rpc "toit_artemis.remove_device" {
    "_device_id": device_id1,
  }
  // The device is still there:
  state = client1.rest.rpc "toit_artemis.get_state" {
    "_device_id": device_id1,
  }
  expect_equals "by anon" state["updated"]

  client1.rest.rpc "toit_artemis.remove_device" {
    "_device_id": device_id1,
  }

  // The device is now gone.
  state = client1.rest.rpc "toit_artemis.get_state" {
    "_device_id": device_id1,
  }
  expect_null state

  storage_id := random_uuid
  path := "$ASSETS_BUCKET/$organization_id/$storage_id"

  // Authenticated can write to the storage.
  // All other users (including anon) can only see it.
  client1.storage.upload
      --path=path
      --content="test".to_byte_array

  // Check that anon can see it with public download.
  expect_equals "test".to_byte_array
      client_anon.storage.download --public --path=path

  // Anon doesn't see it with regular download.
  expect_throws --contains="Not found":
      client_anon.storage.download --path=path

  // Check that anon can't update it.
  expect_throws --contains="row-level security":
    client_anon.storage.upload
        --path=path
        --content="bad".to_byte_array

  // Check that it's still the same.
  expect_equals "test".to_byte_array
      client_anon.storage.download --public --path=path

  storage_id2 := random_uuid
  path2 := "$ASSETS_BUCKET/$organization_id/$storage_id2"
  // Check that anon can't write to it.
  expect_throws --contains="row-level security":
      client_anon.storage.upload
          --path=path2
          --content="test".to_byte_array

  // Create a release.
  // Only authenticated users can do this.
  fleet_id := random_uuid
  release_id := client1.rest.rpc "toit_artemis.insert_release" {
    "_fleet_id": "$fleet_id",
    "_organization_id": "$organization_id",
    "_version": "v1.0.0",
    "_description": "release v1.0.0",
  }

  // Only authenticated users can see the release.
  releases := client1.rest.rpc "toit_artemis.get_releases" {
    "_fleet_id": "$fleet_id",
    "_limit": 100,
  }
  expect_equals 1 releases.size
  expect_equals release_id releases[0]["id"]
  expect_equals "v1.0.0" releases[0]["version"]
  expect_equals "release v1.0.0" releases[0]["description"]
  expect_equals [] releases[0]["tags"]

  // Anon can't see the release.
  releases = client_anon.rest.rpc "toit_artemis.get_releases" {
    "_fleet_id": "$fleet_id",
    "_limit": 100,
  }
  expect releases.is_empty

  // It's not possible to create the same release again.
  expect_throws --contains="unique constraint":
    client1.rest.rpc "toit_artemis.insert_release" {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_version": "v1.0.0",
      "_description": "release v1.0.0",
    }

  // Anon can't create a release.
  expect_throws --contains="row-level security":
    client_anon.rest.rpc "toit_artemis.insert_release" {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_version": "v2.0.0",
      "_description": "release not working",
    }

  // Get the releases by ID.
  releases = client1.rest.rpc "toit_artemis.get_releases_by_ids" {
    "_release_ids": [release_id],
  }
  expect_equals 1 releases.size
  expect_equals release_id releases[0]["id"]

  // Anon still can't see the release.
  releases = client_anon.rest.rpc "toit_artemis.get_releases_by_ids" {
    "_release_ids": [release_id],
  }
  expect releases.is_empty

  // Add some artifacts.
  pod_id1 := random_uuid
  pod_id2 := random_uuid
  client1.rest.rpc "toit_artemis.add_release_artifacts" {
    "_release_id": release_id,
    "_artifacts": [
      {
        "tag": "tag1",
        "pod_id": "$pod_id1",
      },
      {
        "tag": "tag2",
        "pod_id": "$pod_id2",
      },
    ]
  }

  // Anon can't do that.
  pod_id3 := random_uuid
  expect_throws --contains="row-level security":
    client_anon.rest.rpc "toit_artemis.add_release_artifacts" {
      "_release_id": release_id,
      "_artifacts": [
        {
          "tag": "tag3",
          "pod_id": "$pod_id3",
        }
      ]
    }

  // The tag now appears in the release.
  releases = client1.rest.rpc "toit_artemis.get_releases" {
    "_fleet_id": "$fleet_id",
    "_limit": 100,
  }
  expect_equals 1 releases.size
  tags := releases[0]["tags"]
  expect_equals ["tag1", "tag2"] tags.sort

  // We can also find the release by encoded firmware.
  release_ids := client1.rest.rpc "toit_artemis.get_release_ids_for_pod_ids" {
    "_fleet_id": "$fleet_id",
    "_pod_ids": ["$pod_id1"],
  }
  expect_equals 1 release_ids.size
  expect_equals release_id release_ids[0]["id"]
  expect_equals "$pod_id1" release_ids[0]["pod_id"]
  expect_equals "tag1" release_ids[0]["tag"]

  // Anon can't do that.
  release_ids = client_anon.rest.rpc "toit_artemis.get_release_ids_for_pod_ids" {
      "_fleet_id": "$fleet_id",
      "_pod_ids": ["$pod_id1"],
    }
  expect release_ids.is_empty

expect_throws --contains/string [block]:
  exception := catch:
    block.call
    print "Expected exception, but none was thrown."
    expect false
  expect (exception.contains contains)
