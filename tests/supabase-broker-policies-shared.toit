// Copyright (C) 2022 Toitware ApS.

import artemis.cli.config as cli
import artemis.cli.server-config as cli-server-config
import artemis.shared.server-config show ServerConfigSupabase
import expect show *
import log
import supabase
import .broker
import .utils

ASSETS-BUCKET ::= "toit-artemis-assets"
PODS-BUCKET ::= "toit-artemis-pods"

run-shared-test
    --client1/supabase.Client
    --client-anon/supabase.Client
    --organization-id/string="$TEST-ORGANIZATION-UUID"
    --device-id1/string="$random-uuid"
    --device-id2/string="$random-uuid":

  // We only need to worry about the functions that have been copied to the public schema.
  // The tables themselves are inaccessible from the public PostgREST.
  // Each user should only be able to see their own profile.

  // The "toit_artemis.new_provisioned" function is only accessible to
  // authenticated users.
  expect-throws --contains="row-level security":
    client-anon.rest.rpc --schema="toit_artemis" "new_provisioned" {
      "_device_id": device-id1,
      "_state": {:},
    }

  client1.rest.rpc --schema="toit_artemis" "new_provisioned" {
    "_device_id": device-id1,
    "_state": { "created": "by user1" },
  }

  // The device is now available to the authenticated client.
  state := client1.rest.rpc --schema="toit_artemis" "get_state" {
    "_device_id": device-id1,
  }
  expect-equals "by user1" state["created"]

  // Provisioning a device twice should fail.
  expect-throws --contains="duplicate key":
    client1.rest.rpc --schema="toit_artemis" "new_provisioned" {
      "_device_id": device-id1,
      "_state": {:},
    }

  // The "update_state" function is available to anonymous users.
  // They need to know an existing device ID.
  client-anon.rest.rpc --schema="toit_artemis" "update_state" {
    "_device_id": device-id1,
    "_state": { "updated": "by anon" },
  }

  // If the device id isn't known (no call to new_provisioned) the call fails.
  expect-throws --contains="foreign key":
    client-anon.rest.rpc --schema="toit_artemis" "update_state" {
      "_device_id": device-id2,
      "_state": { "updated": "by anon" },
    }

  // The "get_state" function is only available to authenticated users.
  state = client1.rest.rpc --schema="toit_artemis" "get_state" {
    "_device_id": device-id1,
  }
  expect-equals "by anon" state["updated"]

  state = client1.rest.rpc --schema="toit_artemis" "get_state" {
    "_device_id": device-id2,
  }
  expect-null state

  state = client-anon.rest.rpc --schema="toit_artemis" "get_state" {
    "_device_id": device-id1,
  }
  expect-null state

  // report_event is available to devices (and thus anonymous).
  client-anon.rest.rpc --schema="toit_artemis" "report_event" {
    "_device_id": device-id1,
    "_type": "test",
    "_data": { "updated": "by anon" },
  }

  // Only ids in the device-list are valid.
  expect-throws --contains="foreign key":
    client-anon.rest.rpc --schema="toit_artemis" "report_event" {
      "_device_id": "$random-uuid",
      "_type": "test",
      "_data": { "updated": "by anon" },
    }

  // Anon can't get events.
  events := client-anon.rest.rpc --schema="toit_artemis" "get_events" {
      "_device_ids": [device-id1],
      "_types": ["test"],
      "_limit": 1
    }
  expect-equals 0 events.size

  // The events can be retrieved by authenticated users.
  events = client1.rest.rpc --schema="toit_artemis" "get_events" {
    "_device_ids": [device-id1],
    "_types": ["test"],
    "_limit": 1
  }
  expect-equals 1 events.size
  row := events[0]
  expect-equals device-id1 row["device_id"]
  expect-equals "by anon" row["data"]["updated"]

  all-events := client1.rest.rpc --schema="toit_artemis" "get_events" {
    "_device_ids": [device-id1],
    "_types": [],
    "_limit": 10_000,
  }
  all-events-size := all-events.size

  // The "get_goal" function is available to anonymous users.
  // They need to know an existing device ID.
  goal := client-anon.rest.rpc --schema="toit_artemis" "get_goal" {
    "_device_id": device-id1,
  }
  expect-null goal  // Hasn't been set yet.

  all-events = client1.rest.rpc --schema="toit_artemis" "get_events" {
    "_device_ids": [device-id1],
    "_types": [],
    "_limit": 10_000,
  }
  expect-equals all-events-size + 1 all-events.size

  // The "set_goal" function is only available to authenticated users.
  expect-throws --contains="row-level security":
    client-anon.rest.rpc --schema="toit_artemis" "set_goal" {
      "_device_id": device-id1,
      "_goal": { "updated": "by anon" },
    }

  client1.rest.rpc --schema="toit_artemis" "set_goal" {
    "_device_id": device-id1,
    "_goal": { "updated": "by user1" },
  }

  // The goal is now available to the anon client.
  goal = client-anon.rest.rpc --schema="toit_artemis" "get_goal" {
    "_device_id": device-id1,
  }
  expect-equals "by user1" goal["updated"]

  all-events = client1.rest.rpc --schema="toit_artemis" "get_events" {
    "_device_ids": [device-id1],
    "_types": [],
    "_limit": 10_000,
  }
  all-events-size = all-events.size

  // The get_goal_no_event is only available to the CLI.
  goal = client-anon.rest.rpc --schema="toit_artemis" "get_goal_no_event" {
    "_device_id": device-id1,
  }
  expect-null goal

  goal = client1.rest.rpc --schema="toit_artemis" "get_goal_no_event" {
    "_device_id": device-id1,
  }
  expect-equals "by user1" goal["updated"]

  // The no-event version doesn't create an event.
  all-events = client1.rest.rpc --schema="toit_artemis" "get_events" {
    "_device_ids": [device-id1],
    "_types": [],
    "_limit": 10_000,
  }
  expect-equals all-events-size all-events.size

  // Only authenticated can remove devices.
  client-anon.rest.rpc --schema="toit_artemis" "remove_device" {
    "_device_id": device-id1,
  }
  // The device is still there:
  state = client1.rest.rpc --schema="toit_artemis" "get_state" {
    "_device_id": device-id1,
  }
  expect-equals "by anon" state["updated"]

  client1.rest.rpc --schema="toit_artemis" "remove_device" {
    "_device_id": device-id1,
  }

  // The device is now gone.
  state = client1.rest.rpc --schema="toit_artemis" "get_state" {
    "_device_id": device-id1,
  }
  expect-null state

  2.repeat:
    bucket := it == 0 ? ASSETS-BUCKET : PODS-BUCKET
    others-can-see := (bucket == ASSETS-BUCKET)

    storage-id := random-uuid
    path := "$bucket/$organization-id/$storage-id"

    // Authenticated can write to the storage.
    client1.storage.upload
        --path=path
        --contents="test".to-byte-array

    if others-can-see:
      // Check that anon can see it with public download.
      expect-equals "test".to-byte-array
          client-anon.storage.download --public --path=path
    else:
      expect-throws --contains="Not found":
          client-anon.storage.download --public --path=path

    // Anon doesn't see it with regular download.
    expect-throws --contains="Not found":
        client-anon.storage.download --path=path

    // Check that anon can't update it.
    expect-throws --contains="row-level security":
      client-anon.storage.upload
          --path=path
          --contents="bad".to-byte-array

    if others-can-see:
      // Check that it's still the same.
      expect-equals "test".to-byte-array
          client-anon.storage.download --public --path=path

    storage-id2 := random-uuid
    path2 := "$bucket/$organization-id/$storage-id2"
    // Check that anon can't write to it.
    expect-throws --contains="row-level security":
        client-anon.storage.upload
            --path=path2
            --contents="test".to-byte-array

run-shared-pod-description-test
    --client1/supabase.Client
    --other-clients/List
    --organization-id/string="$TEST-ORGANIZATION-UUID":
  other-clients.do: | other-client/supabase.Client |
    // Create a pod description.
    // Only authenticated users can do this.
    fleet-id := random-uuid
    pod-desc1 := "pod_desc1"
    description-id := client1.rest.rpc --schema="toit_artemis" "upsert_pod_description" {
      "_fleet_id": "$fleet-id",
      "_organization_id": "$organization-id",
      "_name": pod-desc1,
      "_description": "pod description 1",
    }

    // Only authenticated users can see the description.
    descriptions := client1.rest.rpc --schema="toit_artemis" "get_pod_descriptions" {
      "_fleet_id": "$fleet-id",
    }
    expect-equals 1 descriptions.size
    expect-equals description-id descriptions[0]["id"]
    expect-equals pod-desc1 descriptions[0]["name"]
    expect-equals "pod description 1" descriptions[0]["description"]

    // Other can't see the description.
    descriptions = other-client.rest.rpc --schema="toit_artemis" "get_pod_descriptions" {
      "_fleet_id": "$fleet-id",
    }
    expect descriptions.is-empty

    // Calling it again updates the description
    client1.rest.rpc --schema="toit_artemis" "upsert_pod_description" {
      "_fleet_id": "$fleet-id",
      "_organization_id": "$organization-id",
      "_name": pod-desc1,
      "_description": "pod description 1 - changed",
    }

    descriptions = client1.rest.rpc --schema="toit_artemis" "get_pod_descriptions" {
      "_fleet_id": "$fleet-id",
    }
    expect-equals 1 descriptions.size
    expect-equals "pod description 1 - changed" descriptions[0]["description"]

    // Other can't create a description.
    pod-name2 := "pod_name2"
    expect-throws --contains="row-level security":
      other-client.rest.rpc --schema="toit_artemis" "upsert_pod_description" {
        "_fleet_id": "$fleet-id",
        "_organization_id": "$organization-id",
        "_name": pod-name2,
        "_description": "pod description 2",
      }

    // Get the descriptions by ID.
    descriptions = client1.rest.rpc --schema="toit_artemis" "get_pod_descriptions_by_ids" {
      "_description_ids": [description-id],
    }
    expect-equals 1 descriptions.size
    expect-equals description-id descriptions[0]["id"]
    expect-equals pod-desc1 descriptions[0]["name"]
    expect-equals "pod description 1 - changed" descriptions[0]["description"]

    // Other still can't see the description.
    descriptions = other-client.rest.rpc --schema="toit_artemis" "get_pod_descriptions_by_ids" {
      "_description_ids": [description-id],
    }
    expect descriptions.is-empty

    pods := client1.rest.rpc --schema="toit_artemis" "get_pods" {
      "_pod_description_id": "$description-id",
      "_limit": 10_000,
      "_offset": 0,
    }
    expect pods.is-empty

    // Add some pods.
    pod-id1 := random-uuid
    pod-id2 := random-uuid
    client1.rest.rpc --schema="toit_artemis" "insert_pod" {
      "_pod_id": "$pod-id1",
      "_pod_description_id": "$description-id",
    }
    client1.rest.rpc --schema="toit_artemis" "insert_pod" {
      "_pod_id": "$pod-id2",
      "_pod_description_id": "$description-id",
    }

    // Other can't do that.
    pod-id3 := random-uuid
    expect-throws --contains="row-level security":
      other-client.rest.rpc --schema="toit_artemis" "insert_pod" {
        "_pod_id": "$pod-id3",
        "_pod_description_id": "$description-id",
      }

    // The pods now appear for the description.
    pods = client1.rest.rpc --schema="toit_artemis" "get_pods" {
      "_pod_description_id": "$description-id",
      "_limit": 10_000,
      "_offset": 0,
    }
    expect-equals 2 pods.size
    // Most recently created pods come first.
    expect-equals "$pod-id2" pods[0]["id"]
    expect-equals "$pod-id1" pods[1]["id"]

    // Other can't see the pods.
    pods = other-client.rest.rpc --schema="toit_artemis" "get_pods" {
      "_pod_description_id": "$description-id",
      "_limit": 10_000,
      "_offset": 0,
    }
    expect pods.is-empty

    // Add tags to the pods.
    client1.rest.rpc --schema="toit_artemis" "set_pod_tag" {
      "_pod_id": "$pod-id1",
      "_pod_description_id": "$description-id",
      "_tag": "tag1",
      "_force": false,
    }
    client1.rest.rpc --schema="toit_artemis" "set_pod_tag" {
      "_pod_id": "$pod-id1",
      "_pod_description_id": "$description-id",
      "_tag": "tag2",
      "_force": false,
    }

    // Other can try, but it won't have any effect.
    other-client.rest.rpc --schema="toit_artemis" "set_pod_tag" {
      "_pod_id": "$pod-id1",
      "_pod_description_id": "$description-id",
      "_tag": "tag3",
      "_force": false,
    }

    // Get the pod1 to see its tags.
    pods = client1.rest.rpc --schema="toit_artemis" "get_pods_by_ids" {
      "_fleet_id": "$fleet-id",
      "_pod_ids": ["$pod-id1"],
    }
    expect-equals 1 pods.size
    expect-equals "$pod-id1" pods[0]["id"]
    expect-equals ["tag1", "tag2"] pods[0]["tags"].sort

    // Only one pod per description is allowed to have the same tag.
    expect-throws --contains="duplicate key value violates unique constraint":
      client1.rest.rpc --schema="toit_artemis" "set_pod_tag" {
        "_pod_id": "$pod-id2",
        "_pod_description_id": "$description-id",
        "_tag": "tag1",
        "_force": false,
      }

    // Other doesn't even see that message.
    other-client.rest.rpc --schema="toit_artemis" "set_pod_tag" {
      "_pod_id": "$pod-id2",
      "_pod_description_id": "$description-id",
      "_tag": "tag1",
      "_force": false,
    }

    // Client1 can remove the tag.
    client1.rest.rpc --schema="toit_artemis" "delete_pod_tag" {
      "_pod_description_id": "$description-id",
      "_tag": "tag1",
    }

    // Other can try, but it won't do anything.
    other-client.rest.rpc --schema="toit_artemis" "delete_pod_tag" {
      "_pod_description_id": "$description-id",
      "_tag": "tag2",
    }

    // Get the pod1 to see its tags.
    pods = client1.rest.rpc --schema="toit_artemis" "get_pods_by_ids" {
      "_fleet_id": "$fleet-id",
      "_pod_ids": ["$pod-id1"],
    }
    expect-equals 1 pods.size
    expect-equals ["tag2"] pods[0]["tags"]

    // Get the pods by name.
    pods = client1.rest.rpc --schema="toit_artemis" "get_pod_descriptions_by_names" {
      "_fleet_id": "$fleet-id",
      "_organization_id": "$organization-id",
      "_names": [pod-desc1],
      "_create_if_absent": false
    }
    expect-equals 1 pods.size
    expect-equals description-id pods[0]["id"]

    // Other doesn't see anything.
    pods = other-client.rest.rpc --schema="toit_artemis" "get_pod_descriptions_by_names" {
      "_fleet_id": "$fleet-id",
      "_organization_id": "$organization-id",
      "_names": [pod-desc1],
      "_create_if_absent": false
    }
    expect pods.is-empty

    // Get pods by name and tag.
    response := client1.rest.rpc --schema="toit_artemis" "get_pods_by_reference" {
      "_fleet_id": "$fleet-id",
      "_references": [
        {
          "name": pod-desc1,
          "tag": "tag2",
        }
      ],
    }
    expect-equals "$pod-id1" response[0]["pod_id"]
    expect-equals "tag2" response[0]["tag"]
    expect-equals pod-desc1 response[0]["name"]

    // Other doesn't see anything.
    response = other-client.rest.rpc --schema="toit_artemis" "get_pods_by_reference" {
      "_fleet_id": "$fleet-id",
      "_references": [
        {
          "name": pod-desc1,
          "tag": "tag2",
        }
      ],
    }
    expect response.is-empty

    // Other can't delete a pod.
    other-client.rest.rpc --schema="toit_artemis" "delete_pods" {
      "_fleet_id": "$fleet-id",
      "_pod_ids": ["$pod-id1"],
    }
    pods = client1.rest.rpc --schema="toit_artemis" "get_pods_by_ids" {
      "_fleet_id": "$fleet-id",
      "_pod_ids": ["$pod-id1"],
    }
    expect-not pods.is-empty

    // Client1 can delete a pod.
    client1.rest.rpc --schema="toit_artemis" "delete_pods" {
      "_fleet_id": "$fleet-id",
      "_pod_ids": ["$pod-id1"],
    }
    pods = client1.rest.rpc --schema="toit_artemis" "get_pods_by_ids" {
      "_fleet_id": "$fleet-id",
      "_pod_ids": ["$pod-id1"],
    }
    expect pods.is-empty

    // Other can't delete a description.
    other-client.rest.rpc --schema="toit_artemis" "delete_pod_descriptions" {
      "_fleet_id": "$fleet-id",
      "_description_ids": ["$description-id"],
    }
    descriptions = client1.rest.rpc --schema="toit_artemis" "get_pod_descriptions_by_ids" {
      "_description_ids": [description-id],
    }
    expect-not descriptions.is-empty

    // Client1 can delete a description.
    client1.rest.rpc --schema="toit_artemis" "delete_pod_descriptions" {
      "_fleet_id": "$fleet-id",
      "_description_ids": ["$description-id"],
    }
    descriptions = client1.rest.rpc --schema="toit_artemis" "get_pod_descriptions_by_ids" {
      "_description_ids": [description-id],
    }
    expect descriptions.is-empty
