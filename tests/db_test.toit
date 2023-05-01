// Copyright (C) 2023 Toitware ApS. All rights reserved.

// ARTEMIS_TEST_FLAGS: BROKER

import expect show *
import log
import net
import artemis.cli.brokers.broker
import artemis.cli.release show Release
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

    test_releases --test_broker=test_broker broker_cli

test_releases --test_broker/TestBroker broker_cli/broker.BrokerCli:
  fleet_id := random_uuid

  // Get the list of releases. Should be emtpy.
  releases := broker_cli.release_get --fleet_id=fleet_id
  expect releases.is_empty

  // Create a release.
  release_id := broker_cli.release_create
      --fleet_id=fleet_id
      --organization_id=TEST_ORGANIZATION_UUID
      --version="version1"
      --description=null
  releases = broker_cli.release_get --fleet_id=fleet_id
  expect_equals 1 releases.size
  release/Release := releases[0]
  expect_equals "version1" release.version
  expect_null release.description
  expect release.groups.is_empty

  // Create another release.
  release_id2 := broker_cli.release_create
      --fleet_id=fleet_id
      --organization_id=TEST_ORGANIZATION_UUID
      --version="version2"
      --description="description2"
  releases = broker_cli.release_get --fleet_id=fleet_id
  expect_equals 2 releases.size
  index1 := releases[0].version == "version1" ? 0 : 1
  index2 := index1 == 0 ? 1 : 0
  expect_equals "version1" releases[index1].version
  expect_null releases[index1].description
  expect releases[index1].groups.is_empty

  expect_equals "version2" releases[index2].version
  expect_equals "description2" releases[index2].description
  expect releases[index2].groups.is_empty

  // Get the release by id.
  releases = broker_cli.release_get --release_ids=[release_id]
  expect_equals 1 releases.size
  release = releases[0]
  expect_equals "version1" release.version

  releases = broker_cli.release_get --release_ids=[release_id, release_id2]
  expect_equals 2 releases.size
  index1 = releases[0].version == "version1" ? 0 : 1
  index2 = index1 == 0 ? 1 : 0
  expect_equals "version1" releases[index1].version
  expect_equals "version2" releases[index2].version

  // Add artifacts.
  broker_cli.release_add_artifact
      --release_id=release_id
      --group=""
      --encoded_firmware="firmware1"

  releases = broker_cli.release_get --release_ids=[release_id]
  expect_equals 1 releases.size
  release = releases[0]
  expect_equals 1 release.groups.size
  expect_equals "" release.groups[0]

  // Find the firmware for an encoded firmware.
  release_ids := broker_cli.release_get_ids_for
      --fleet_id=fleet_id
      --encoded_firmwares=["firmware1"]
  expect_equals 1 release_ids.size
  expect_equals release_id release_ids["firmware1"]

  groups := ["foo", "bar", "gee"]
  groups.do:
    broker_cli.release_add_artifact
        --release_id=release_id2
        --group=it
        --encoded_firmware="firmware-$it"

  releases = broker_cli.release_get --release_ids=[release_id2]
  expect_equals 1 releases.size
  release = releases[0]
  expect_equals 3 release.groups.size
  set := {}
  set.add_all release.groups
  groups.do: expect (set.contains it)

  // Find the firmware for an encoded firmware.
  release_ids = broker_cli.release_get_ids_for
      --fleet_id=fleet_id
      --encoded_firmwares=["firmware-foo", "firmware-bar"]
  expect_equals 2 release_ids.size
  expect_equals release_id2 release_ids["firmware-foo"]
  expect_equals release_id2 release_ids["firmware-bar"]

  // Find the firmware for an encoded firmware.
  release_ids = broker_cli.release_get_ids_for
      --fleet_id=fleet_id
      --encoded_firmwares=["firmware1", "firmware-bar", "firmware-gee"]
  expect_equals 3 release_ids.size
  expect_equals release_id release_ids["firmware1"]
  expect_equals release_id2 release_ids["firmware-bar"]
  expect_equals release_id2 release_ids["firmware-gee"]

  // Find the firmware for an non existing encoded firmware.
  encoded_firmwares := ["firmware1", "firmware-bar", "firmware-unknown", "firmware-gee", "firmware-unknown2"]
  release_ids = broker_cli.release_get_ids_for
      --fleet_id=fleet_id
      --encoded_firmwares=encoded_firmwares
  expect_equals 3 release_ids.size
  expect_equals release_id release_ids["firmware1"]
  expect_equals release_id2 release_ids["firmware-bar"]
  expect_equals release_id2 release_ids["firmware-gee"]
