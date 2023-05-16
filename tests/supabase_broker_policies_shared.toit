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
PODS_BUCKET ::= "toit-artemis-pods"

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

  2.repeat:
    bucket := it == 0 ? ASSETS_BUCKET : PODS_BUCKET
    others_can_see := (bucket == ASSETS_BUCKET)

    storage_id := random_uuid
    path := "$bucket/$organization_id/$storage_id"

    // Authenticated can write to the storage.
    client1.storage.upload
        --path=path
        --content="test".to_byte_array

    if others_can_see:
      // Check that anon can see it with public download.
      expect_equals "test".to_byte_array
          client_anon.storage.download --public --path=path
    else:
      expect_throws --contains="Not found":
          client_anon.storage.download --public --path=path

    // Anon doesn't see it with regular download.
    expect_throws --contains="Not found":
        client_anon.storage.download --path=path

    // Check that anon can't update it.
    expect_throws --contains="row-level security":
      client_anon.storage.upload
          --path=path
          --content="bad".to_byte_array

    if others_can_see:
      // Check that it's still the same.
      expect_equals "test".to_byte_array
          client_anon.storage.download --public --path=path

    storage_id2 := random_uuid
    path2 := "$bucket/$organization_id/$storage_id2"
    // Check that anon can't write to it.
    expect_throws --contains="row-level security":
        client_anon.storage.upload
            --path=path2
            --content="test".to_byte_array

run_shared_pod_description_test
    --client1/supabase.Client
    --other_clients/List
    --organization_id/string="$TEST_ORGANIZATION_UUID":
  other_clients.do: | other_client/supabase.Client |
    // Create a pod description.
    // Only authenticated users can do this.
    fleet_id := random_uuid
    pod_desc1 := "pod_desc1"
    description_id := client1.rest.rpc "toit_artemis.upsert_pod_description" {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_name": pod_desc1,
      "_description": "pod description 1",
    }

    // Only authenticated users can see the description.
    descriptions := client1.rest.rpc "toit_artemis.get_pod_descriptions" {
      "_fleet_id": "$fleet_id",
    }
    expect_equals 1 descriptions.size
    expect_equals description_id descriptions[0]["id"]
    expect_equals pod_desc1 descriptions[0]["name"]
    expect_equals "pod description 1" descriptions[0]["description"]

    // Other can't see the description.
    descriptions = other_client.rest.rpc "toit_artemis.get_pod_descriptions" {
      "_fleet_id": "$fleet_id",
    }
    expect descriptions.is_empty

    // Calling it again updates the description
    client1.rest.rpc "toit_artemis.upsert_pod_description" {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_name": pod_desc1,
      "_description": "pod description 1 - changed",
    }

    descriptions = client1.rest.rpc "toit_artemis.get_pod_descriptions" {
      "_fleet_id": "$fleet_id",
    }
    expect_equals 1 descriptions.size
    expect_equals "pod description 1 - changed" descriptions[0]["description"]

    // Other can't create a description.
    pod_name2 := "pod_name2"
    expect_throws --contains="row-level security":
      other_client.rest.rpc "toit_artemis.upsert_pod_description" {
        "_fleet_id": "$fleet_id",
        "_organization_id": "$organization_id",
        "_name": pod_name2,
        "_description": "pod description 2",
      }

    // Get the descriptions by ID.
    descriptions = client1.rest.rpc "toit_artemis.get_pod_descriptions_by_ids" {
      "_description_ids": [description_id],
    }
    expect_equals 1 descriptions.size
    expect_equals description_id descriptions[0]["id"]
    expect_equals pod_desc1 descriptions[0]["name"]
    expect_equals "pod description 1 - changed" descriptions[0]["description"]

    // Other still can't see the description.
    descriptions = other_client.rest.rpc "toit_artemis.get_pod_descriptions_by_ids" {
      "_description_ids": [description_id],
    }
    expect descriptions.is_empty

    pods := client1.rest.rpc "toit_artemis.get_pods" {
      "_pod_description_id": "$description_id",
      "_limit": 10_000,
      "_offset": 0,
    }
    expect pods.is_empty

    // Add some pods.
    pod_id1 := random_uuid
    pod_id2 := random_uuid
    client1.rest.rpc "toit_artemis.insert_pod" {
      "_pod_id": "$pod_id1",
      "_pod_description_id": "$description_id",
    }
    client1.rest.rpc "toit_artemis.insert_pod" {
      "_pod_id": "$pod_id2",
      "_pod_description_id": "$description_id",
    }

    // Other can't do that.
    pod_id3 := random_uuid
    expect_throws --contains="row-level security":
      other_client.rest.rpc "toit_artemis.insert_pod" {
        "_pod_id": "$pod_id3",
        "_pod_description_id": "$description_id",
      }

    // The pods now appear for the description.
    pods = client1.rest.rpc "toit_artemis.get_pods" {
      "_pod_description_id": "$description_id",
      "_limit": 10_000,
      "_offset": 0,
    }
    expect_equals 2 pods.size
    // Most recently created pods come first.
    expect_equals "$pod_id2" pods[0]["id"]
    expect_equals "$pod_id1" pods[1]["id"]

    // Other can't see the pods.
    pods = other_client.rest.rpc "toit_artemis.get_pods" {
      "_pod_description_id": "$description_id",
      "_limit": 10_000,
      "_offset": 0,
    }
    expect pods.is_empty

    // Add tags to the pods.
    client1.rest.rpc "toit_artemis.set_pod_tag" {
      "_pod_id": "$pod_id1",
      "_pod_description_id": "$description_id",
      "_tag": "tag1",
      "_force": false,
    }
    client1.rest.rpc "toit_artemis.set_pod_tag" {
      "_pod_id": "$pod_id1",
      "_pod_description_id": "$description_id",
      "_tag": "tag2",
      "_force": false,
    }

    // Other can try, but it won't have any effect.
    other_client.rest.rpc "toit_artemis.set_pod_tag" {
      "_pod_id": "$pod_id1",
      "_pod_description_id": "$description_id",
      "_tag": "tag3",
      "_force": false,
    }

    // Get the pod1 to see its tags.
    pods = client1.rest.rpc "toit_artemis.get_pods_by_ids" {
      "_fleet_id": "$fleet_id",
      "_pod_ids": ["$pod_id1"],
    }
    expect_equals 1 pods.size
    expect_equals "$pod_id1" pods[0]["id"]
    expect_equals ["tag1", "tag2"] pods[0]["tags"]

    // Only one pod per description is allowed to have the same tag.
    expect_throws --contains="duplicate key value violates unique constraint":
      client1.rest.rpc "toit_artemis.set_pod_tag" {
        "_pod_id": "$pod_id2",
        "_pod_description_id": "$description_id",
        "_tag": "tag1",
        "_force": false,
      }

    // Other doesn't even see that message.
    other_client.rest.rpc "toit_artemis.set_pod_tag" {
      "_pod_id": "$pod_id2",
      "_pod_description_id": "$description_id",
      "_tag": "tag1",
      "_force": false,
    }

    // Client1 can remove the tag.
    client1.rest.rpc "toit_artemis.delete_pod_tag" {
      "_pod_description_id": "$description_id",
      "_tag": "tag1",
    }

    // Other can try, but it won't do anything.
    other_client.rest.rpc "toit_artemis.delete_pod_tag" {
      "_pod_description_id": "$description_id",
      "_tag": "tag2",
    }

    // Get the pod1 to see its tags.
    pods = client1.rest.rpc "toit_artemis.get_pods_by_ids" {
      "_fleet_id": "$fleet_id",
      "_pod_ids": ["$pod_id1"],
    }
    expect_equals 1 pods.size
    expect_equals ["tag2"] pods[0]["tags"]

    // Get the pods by name.
    pods = client1.rest.rpc "toit_artemis.get_pod_descriptions_by_names" {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_names": [pod_desc1],
      "_create_if_absent": false
    }
    expect_equals 1 pods.size
    expect_equals description_id pods[0]["id"]

    // Other doesn't see anything.
    pods = other_client.rest.rpc "toit_artemis.get_pod_descriptions_by_names" {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_names": [pod_desc1],
      "_create_if_absent": false
    }
    expect pods.is_empty

    // Get pods by name and tag.
    response := client1.rest.rpc "toit_artemis.get_pods_by_reference" {
      "_fleet_id": "$fleet_id",
      "_references": [
        {
          "name": pod_desc1,
          "tag": "tag2",
        }
      ],
    }
    expect_equals "$pod_id1" response[0]["pod_id"]
    expect_equals "tag2" response[0]["tag"]
    expect_equals pod_desc1 response[0]["name"]

    // Other doesn't see anything.
    response = other_client.rest.rpc "toit_artemis.get_pods_by_reference" {
      "_fleet_id": "$fleet_id",
      "_references": [
        {
          "name": pod_desc1,
          "tag": "tag2",
        }
      ],
    }
    expect response.is_empty
