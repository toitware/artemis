// Copyright (C) 2023 Toitware ApS. All rights reserved.

// ARTEMIS_TEST_FLAGS: BROKER

import expect show *
import log
import net
import artemis.cli.brokers.broker
import artemis.cli.pod_registry show *
import artemis.service.brokers.broker
import artemis.cli.brokers.supabase show BrokerCliSupabase

import .broker
import .utils

main args:
  broker_type := broker_type_from_args args
  with_broker --type=broker_type: | test_broker/TestBroker |
    run_test broker_type test_broker

run_test
    broker_name/string
    test_broker/TestBroker:

  test_broker.with_cli: | broker_cli/broker.BrokerCli |
    if broker_cli is BrokerCliSupabase:
      // Make sure we are authenticated.
      broker_cli.ensure_authenticated:
        broker_cli.sign_in --email=TEST_EXAMPLE_COM_EMAIL --password=TEST_EXAMPLE_COM_PASSWORD

    test_pod_registry --test_broker=test_broker broker_cli

test_pod_registry --test_broker/TestBroker broker_cli/broker.BrokerCli:
  fleet_id := random_uuid

  // Get the list of descriptions. Should be emtpy.
  descriptions := broker_cli.pod_registry_descriptions --fleet_id=fleet_id
  expect descriptions.is_empty

  // Create a description.
  description_id := broker_cli.pod_registry_description_upsert
      --fleet_id=fleet_id
      --organization_id=TEST_ORGANIZATION_UUID
      --name="pod1"
      --description=null
  descriptions = broker_cli.pod_registry_descriptions --fleet_id=fleet_id
  expect_equals 1 descriptions.size
  description/PodRegistryDescription := descriptions[0]
  expect_equals "pod1" description.name
  expect_null description.description

  // Create another description.
  description_id2 := broker_cli.pod_registry_description_upsert
      --fleet_id=fleet_id
      --organization_id=TEST_ORGANIZATION_UUID
      --name="pod2"
      --description="description2"
  descriptions = broker_cli.pod_registry_descriptions --fleet_id=fleet_id
  expect_equals 2 descriptions.size
  index1 := descriptions[0].name == "pod1" ? 0 : 1
  index2 := index1 == 0 ? 1 : 0
  expect_equals "pod1" descriptions[index1].name
  expect_null descriptions[index1].description
  expect_equals "pod2" descriptions[index2].name
  expect_equals "description2" descriptions[index2].description

  // Get the descriptions by id.
  descriptions = broker_cli.pod_registry_descriptions --ids=[description_id]
  expect_equals 1 descriptions.size
  description = descriptions[0]
  expect_equals "pod1" description.name

  descriptions = broker_cli.pod_registry_descriptions --ids=[description_id, description_id2]
  expect_equals 2 descriptions.size
  index1 = descriptions[0].name == "pod1" ? 0 : 1
  index2 = index1 == 0 ? 1 : 0
  expect_equals "pod1" descriptions[index1].name
  expect_equals "pod2" descriptions[index2].name

  // Get the descriptions by name.
  descriptions = broker_cli.pod_registry_descriptions --fleet_id=fleet_id --names=["pod1"]
  expect_equals 1 descriptions.size
  description = descriptions[0]
  expect_equals "pod1" description.name

  // Add a pod.
  pod_id1 := random_uuid
  broker_cli.pod_registry_add
      --pod_description_id=description_id
      --pod_id=pod_id1

  pods := broker_cli.pod_registry_pods --pod_description_id=description_id
  expect_equals 1 pods.size
  pod/PodRegistryEntry := pods[0]
  expect_equals pod_id1 pod.id
  expect_equals description_id pod.pod_description_id
  expect_equals 1 pod.revision

  // Tag the pod.
  broker_cli.pod_registry_tag_set
      --pod_description_id=description_id
      --pod_id=pod_id1
      --tag="tag1"

  // Get the pod by id.
  pods = broker_cli.pod_registry_pods --fleet_id=fleet_id --pod_ids=[pod_id1]
  expect_equals 1 pods.size
  pod = pods[0]
  expect_equals pod_id1 pod.id
  expect_equals description_id pod.pod_description_id
  expect_equals 1 pod.revision
  expect_equals 1 pod.tags.size
  expect_equals "tag1" pod.tags[0]

  // Add another tag to pod1.
  broker_cli.pod_registry_tag_set
      --pod_description_id=description_id
      --pod_id=pod_id1
      --tag="tag1-2"

  // Get the pod by id and check the tag.
  pods = broker_cli.pod_registry_pods --fleet_id=fleet_id --pod_ids=[pod_id1]
  expect_equals 1 pods.size
  pod = pods[0]
  expect_equals pod_id1 pod.id
  expect_equals description_id pod.pod_description_id
  expect_equals "tag1" pod.tags[0]
  expect_equals "tag1-2" pod.tags[1]

  // Remove the tag again.
  broker_cli.pod_registry_tag_remove
      --pod_description_id=description_id
      --tag="tag1-2"

  // Get the pod by id and check the tag.
  pods = broker_cli.pod_registry_pods --fleet_id=fleet_id --pod_ids=[pod_id1]
  expect_equals 1 pods.size
  pod = pods[0]
  expect_equals pod_id1 pod.id
  expect_equals 1 pod.tags.size
  expect_equals "tag1" pod.tags[0]

  // Add a few more pods.
  pod_id2 := random_uuid
  broker_cli.pod_registry_add
      --pod_description_id=description_id
      --pod_id=pod_id2
  broker_cli.pod_registry_tag_set
      --pod_description_id=description_id
      --pod_id=pod_id2
      --tag="tag_pod2"
  broker_cli.pod_registry_tag_set
      --pod_description_id=description_id
      --pod_id=pod_id2
      --tag="tag_pod2-2"
  broker_cli.pod_registry_tag_set
      --pod_description_id=description_id
      --pod_id=pod_id2
      --tag="tag_pod2-3"

  pod_id3 := random_uuid
  broker_cli.pod_registry_add
      --pod_description_id=description_id2
      --pod_id=pod_id3
  broker_cli.pod_registry_tag_set
      --pod_description_id=description_id2
      --pod_id=pod_id3
      --tag="tag_pod3"

  pod_id4 := random_uuid
  broker_cli.pod_registry_add
      --pod_description_id=description_id2
      --pod_id=pod_id4
  broker_cli.pod_registry_tag_set
      --pod_description_id=description_id2
      --pod_id=pod_id4
      --tag="tag_pod4"

  names_tags := [
    {
      "name": "pod1",
      "tag": "tag1",
    },
    {
      "name": "pod1",
      "tag": "tag_pod2-2",
    },
    {
      "name": "pod2",
      "tag": "tag_pod4",
    },
  ]
  // Get the pod ids given names and tags.
  pod_ids := broker_cli.pod_registry_pod_ids
      --fleet_id=fleet_id
      --names_tags=names_tags
  expect_equals 3 pod_ids.size
  seen := {}
  pod_ids.do:
    name := it["name"]
    tag := it["tag"]
    pod_id := it["pod_id"]
    seen.add pod_id
    if name == "pod1" and tag == "tag1":
      expect_equals pod_id pod_id
    else if name == "pod1" and tag == "tag_pod2-2":
      expect_equals pod_id2 pod_id
    else:
      expect_equals "pod2" name
      expect_equals "tag_pod4" tag
      expect_equals pod_id4 pod_id
  expect_equals 3 seen.size