// Copyright (C) 2023 Toitware ApS. All rights reserved.

// ARTEMIS_TEST_FLAGS: BROKER

import encoding.ubjson
import expect show *
import log
import net
import artemis.cli.brokers.broker
import artemis.cli.pod-registry show *
import artemis.service.brokers.broker

import .broker
import .utils

main args:
  broker-type := broker-type-from-args args
  with-broker --args=args --type=broker-type: | test-broker/TestBroker |
    run-test broker-type test-broker

run-test
    broker-name/string
    test-broker/TestBroker:

  test-broker.with-cli: | broker-cli/broker.BrokerCli |
    // Make sure we are authenticated.
    broker-cli.ensure-authenticated:
      broker-cli.sign-in --email=TEST-EXAMPLE-COM-EMAIL --password=TEST-EXAMPLE-COM-PASSWORD

    test-pod-registry --test-broker=test-broker broker-cli
    test-pods --test-broker=test-broker broker-cli

test-pod-registry --test-broker/TestBroker broker-cli/broker.BrokerCli:
  fleet-id := random-uuid

  // Get the list of descriptions. Should be emtpy.
  descriptions := broker-cli.pod-registry-descriptions --fleet-id=fleet-id
  expect descriptions.is-empty

  // Create a description.
  description-id := broker-cli.pod-registry-description-upsert
      --fleet-id=fleet-id
      --organization-id=TEST-ORGANIZATION-UUID
      --name="pod1"
      --description=null
  descriptions = broker-cli.pod-registry-descriptions --fleet-id=fleet-id
  expect-equals 1 descriptions.size
  description/PodRegistryDescription := descriptions[0]
  expect-equals "pod1" description.name
  expect-null description.description

  // Create the same description again.
  description-id-received := broker-cli.pod-registry-description-upsert
      --fleet-id=fleet-id
      --organization-id=TEST-ORGANIZATION-UUID
      --name="pod1"
      --description=null
  expect-equals description-id description-id-received

  // Create another description.
  description-id2 := broker-cli.pod-registry-description-upsert
      --fleet-id=fleet-id
      --organization-id=TEST-ORGANIZATION-UUID
      --name="pod2"
      --description="description2"
  descriptions = broker-cli.pod-registry-descriptions --fleet-id=fleet-id
  names := descriptions.map:
    if it.name == "pod2":
      expect-equals "description2" it.description
    it.name
  names.sort --in-place
  expect-equals ["pod1", "pod2"] names

  // Get the descriptions by id.
  descriptions = broker-cli.pod-registry-descriptions --ids=[description-id]
  expect-equals 1 descriptions.size
  description = descriptions[0]
  expect-equals "pod1" description.name

  descriptions = broker-cli.pod-registry-descriptions --ids=[description-id, description-id2]
  names = descriptions.map: it.name
  names.sort --in-place
  expect-equals ["pod1", "pod2"] names

  // Get the descriptions by name.
  descriptions = broker-cli.pod-registry-descriptions
      --fleet-id=fleet-id
      --organization-id=TEST-ORGANIZATION-UUID
      --names=["pod1"]
      --no-create-if-absent
  expect-equals 1 descriptions.size
  description = descriptions[0]
  expect-equals "pod1" description.name

  // Do the same but create the missing description.
  descriptions = broker-cli.pod-registry-descriptions
      --fleet-id=fleet-id
      --organization-id=TEST-ORGANIZATION-UUID
      --names=["pod1", "pod3"]
      --create-if-absent
  names = descriptions.map: it.name
  names.sort --in-place
  expect-equals ["pod1", "pod3"] names

  // Add a pod.
  pod1-creation-start := Time.now
  pod-id1 := random-uuid
  broker-cli.pod-registry-add
      --pod-description-id=description-id
      --pod-id=pod-id1

  pods := broker-cli.pod-registry-pods --pod-description-id=description-id
  expect-equals 1 pods.size
  pod/PodRegistryEntry := pods[0]
  expect-equals pod-id1 pod.id
  expect-equals description-id pod.pod-description-id
  expect-equals 1 pod.revision
  timestamp := pod.created-at
  expect timestamp >= pod1-creation-start
  expect timestamp <= Time.now

  // Tag the pod.
  broker-cli.pod-registry-tag-set
      --pod-description-id=description-id
      --pod-id=pod-id1
      --tag="tag1"

  // Get the pod by id.
  pods = broker-cli.pod-registry-pods --fleet-id=fleet-id --pod-ids=[pod-id1]
  expect-equals 1 pods.size
  pod = pods[0]
  expect-equals pod-id1 pod.id
  expect-equals description-id pod.pod-description-id
  expect-equals 1 pod.revision
  expect-equals 1 pod.tags.size
  expect-equals "tag1" pod.tags[0]

  // Add another tag to pod1.
  broker-cli.pod-registry-tag-set
      --pod-description-id=description-id
      --pod-id=pod-id1
      --tag="tag1-2"

  // Get the pod by id and check the tag.
  pods = broker-cli.pod-registry-pods --fleet-id=fleet-id --pod-ids=[pod-id1]
  expect-equals 1 pods.size
  pod = pods[0]
  expect-equals pod-id1 pod.id
  expect-equals description-id pod.pod-description-id
  expect-equals "tag1" pod.tags[0]
  expect-equals "tag1-2" pod.tags[1]

  // Remove the tag again.
  broker-cli.pod-registry-tag-remove
      --pod-description-id=description-id
      --tag="tag1-2"

  // Get the pod by id and check the tag.
  pods = broker-cli.pod-registry-pods --fleet-id=fleet-id --pod-ids=[pod-id1]
  expect-equals 1 pods.size
  pod = pods[0]
  expect-equals pod-id1 pod.id
  expect-equals 1 pod.tags.size
  expect-equals "tag1" pod.tags[0]

  // Add a few more pods.
  pod-id2 := random-uuid
  broker-cli.pod-registry-add
      --pod-description-id=description-id
      --pod-id=pod-id2
  broker-cli.pod-registry-tag-set
      --pod-description-id=description-id
      --pod-id=pod-id2
      --tag="tag_pod2"
  broker-cli.pod-registry-tag-set
      --pod-description-id=description-id
      --pod-id=pod-id2
      --tag="tag_pod2-2"
  broker-cli.pod-registry-tag-set
      --pod-description-id=description-id
      --pod-id=pod-id2
      --tag="tag_pod2-3"

  broker-cli.pod-registry-tag-set
      --pod-description-id=description-id
      --pod-id=pod-id1
      --tag="test-tag-force"

  // Check for an error when reusing a tag.
  expect-throws --check-exception=(: it.contains "duplicate" or it.contains "already"):
    broker-cli.pod-registry-tag-set
        --pod-description-id=description-id
        --pod-id=pod-id2
        --tag="test-tag-force"

  // It works when using the force flag.
  broker-cli.pod-registry-tag-set
      --pod-description-id=description-id
      --pod-id=pod-id2
      --tag="test-tag-force"
      --force

  pod-id3 := random-uuid
  broker-cli.pod-registry-add
      --pod-description-id=description-id2
      --pod-id=pod-id3
  broker-cli.pod-registry-tag-set
      --pod-description-id=description-id2
      --pod-id=pod-id3
      --tag="tag_pod3"

  pod-id4 := random-uuid
  broker-cli.pod-registry-add
      --pod-description-id=description-id2
      --pod-id=pod-id4
  broker-cli.pod-registry-tag-set
      --pod-description-id=description-id2
      --pod-id=pod-id4
      --tag="tag_pod4"

  pods = broker-cli.pod-registry-pods --pod-description-id=description-id
  expect-equals 2 pods.size
  // Make sure that the more recent pod is first.
  pod2 := pods[0]
  pod1 := pods[1]
  expect-equals pod-id1 pod1.id
  expect-equals pod-id2 pod2.id

  reference-tests := [
    [pod-id1, PodReference --name="pod1" --tag="tag1"],
    [pod-id2, PodReference --name="pod1" --tag="tag_pod2-2"],
    [pod-id4, PodReference --name="pod2" --tag="tag_pod4"],
    [pod-id2, PodReference --name="pod1" --tag="test-tag-force"],
    [pod-id1, PodReference --name="pod1" --revision=1],
    [pod-id2, PodReference --name="pod1" --revision=2],
    [pod-id3, PodReference --name="pod2" --revision=1],
    [pod-id4, PodReference --name="pod2" --revision=2],
    [null, PodReference --name="pod1" --tag="not found"],
    [null, PodReference --name="pod1" --revision=499],
  ]
  // Get the pod ids given names and tags.
  pod-ids := broker-cli.pod-registry-pod-ids
      --fleet-id=fleet-id
      --references=reference-tests.map: it[1]
  count := 0
  reference-tests.do: | row/List |
    expected-id := row[0]
    reference/PodReference := row[1]
    if expected-id == null:
      expect-not (pod-ids.contains reference)
    else:
      count++
      expect-equals expected-id pod-ids[reference]
  expect-equals count pod-ids.size

  // Test deletion.
  broker-cli.pod-registry-delete --pod-ids=[pod-id1, pod-id3] --fleet-id=fleet-id
  pods = broker-cli.pod-registry-pods --pod-description-id=description-id
  expect-equals 1 pods.size
  pod2 = pods[0]
  expect-equals pod-id2 pod2.id
  pods = broker-cli.pod-registry-pods --pod-description-id=description-id2
  expect-equals 1 pods.size
  pod4 := pods[0]
  expect-equals pod-id4 pod4.id

  description-id3 := broker-cli.pod-registry-description-upsert
      --fleet-id=fleet-id
      --organization-id=TEST-ORGANIZATION-UUID
      --name="pod3"
      --description=null

  description-id4 := broker-cli.pod-registry-description-upsert
      --fleet-id=fleet-id
      --organization-id=TEST-ORGANIZATION-UUID
      --name="pod4"
      --description=null

  descriptions = broker-cli.pod-registry-descriptions --fleet-id=fleet-id
  expect-equals 4 descriptions.size
  seen := {}
  descriptions.do: | description/PodRegistryDescription |
    expect-not (seen.contains description.id)
    seen.add description.id
  expect (seen.contains description-id)
  expect (seen.contains description-id2)
  expect (seen.contains description-id3)
  expect (seen.contains description-id4)

  broker-cli.pod-registry-descriptions-delete --fleet-id=fleet-id
      --description-ids=[
        description-id,
        description-id3,
        description-id4,
      ]
  descriptions = broker-cli.pod-registry-descriptions --fleet-id=fleet-id
  expect-equals 1 descriptions.size
  description = descriptions[0]
  expect-equals description-id2 description.id

  // The pods inside the deleted descriptions were also deleted.
  pods = broker-cli.pod-registry-pods --fleet-id=fleet-id --pod-ids=[pod-id2]
  expect-equals 0 pods.size


test-pods --test-broker/TestBroker broker-cli/broker.BrokerCli:
  3.repeat: | iteration |
    pod-id := random-uuid
    id1 := "$random-uuid"
    id2 := "$random-uuid"
    id3 := "myMXwslBoXkTDQ0olhq1QsiHRWWL4yj1V0IuoK+PYOg="
    pod-contents := {
      id1: "entry1 - $iteration",
      id2: "entry2 - $iteration",
      id3: "sha256 base64 - $iteration",
    }
    pod := {
      "name1": id1,
      "name2": id2,
      "name3": id3,
    }

    pod-contents.do: | key/string value/string |
      broker-cli.pod-registry-upload-pod-part
          --organization-id=TEST-ORGANIZATION-UUID
          --part-id=key
          value.to-byte-array

    // Upload the keys as a manifest.
    manifest := ubjson.encode pod
    broker-cli.pod-registry-upload-pod-manifest
        --organization-id=TEST-ORGANIZATION-UUID
        --pod-id=pod-id
        manifest

    // Download the manifest.
    downloaded-manifest := broker-cli.pod-registry-download-pod-manifest
        --organization-id=TEST-ORGANIZATION-UUID
        --pod-id=pod-id
    expect-equals manifest downloaded-manifest
    decoded := ubjson.decode downloaded-manifest
    expect-equals pod.keys decoded.keys
    expect-equals pod.values decoded.values

    // Download the parts.
    decoded.do: | _ id/string |
      downloaded-part := broker-cli.pod-registry-download-pod-part id
          --organization-id=TEST-ORGANIZATION-UUID
      expect-equals pod-contents[id] downloaded-part.to-string
