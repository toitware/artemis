// Copyright (C) 2022 Toitware ApS. All rights reserved.

// ARTEMIS_TEST_FLAGS: BROKER

import expect show *
import log
import monitor
import net
import reader show Reader
import artemis.cli.brokers.broker
import artemis.cli.device show DeviceDetailed
import artemis.service.device show Device
import artemis.cli.event show Event
import artemis.service.brokers.broker
import artemis.cli.brokers.mqtt.base as mqtt_broker
import artemis.cli.brokers.http.base as http_broker
import artemis.cli.brokers.supabase show BrokerCliSupabase
import artemis.service.brokers.mqtt.synchronize as mqtt_broker
import supabase
import supabase.auth as supabase
import supabase.utils
import uuid

import .artemis_server
  show
    with_artemis_server
    TestArtemisServer
    SupabaseBackdoor
import .broker
import .utils

// When running the supabase test we need valid device ids
// that are not already in the database.
DEVICE1 ::= Device
    --id=random_uuid_string
    --hardware_id=random_uuid_string
    --organization_id=TEST_ORGANIZATION_UUID
    --firmware_state={:}
DEVICE2 ::= Device
    --id=random_uuid_string
    --hardware_id=random_uuid_string
    --organization_id=TEST_ORGANIZATION_UUID
    --firmware_state={:}

main args:
  broker_type := broker_type_from_args args
  with_broker --type=broker_type: | test_broker/TestBroker |
    run_test broker_type test_broker

run_test
    broker_name/string
    test_broker/TestBroker:

  // We are going to reuse the cli for all tests (and only authenticate once).
  // However, we will need multiple services.
  test_broker.with_cli: | broker_cli/broker.BrokerCli |
    if broker_cli is BrokerCliSupabase:
      // Make sure we are authenticated.
      broker_cli.ensure_authenticated: | auth/supabase.Auth |
        auth.sign_in --email=TEST_EXAMPLE_COM_EMAIL --password=TEST_EXAMPLE_COM_PASSWORD

    if broker_name == "supabase-local-artemis":
      // Make sure the device is in the database.
      with_artemis_server --type="supabase": | server/TestArtemisServer |
        backdoor := server.backdoor as SupabaseBackdoor
        backdoor.with_backdoor_client_: | client/supabase.Client |
          [DEVICE1, DEVICE2].do: | device/Device |
            client.rest.insert "devices" {
              "alias": device.id,
              "organization_id": device.organization_id,
            }

    [DEVICE1, DEVICE2].do: | device/Device |
      identity := {
        "device_id": device.id,
        "organization_id": device.organization_id,
        "hardware_id": device.hardware_id,
      }
      state := {
        "identity": identity,
      }
      broker_cli.notify_created --device_id=device.id --state=state

    network = net.open
    try:
      test_image --test_broker=test_broker broker_cli
      test_firmware --test_broker=test_broker broker_cli
      test_goal --test_broker=test_broker broker_cli
      // Test the events last, as it depends on test_goal to have run.
      // It also does state updates which could interfere with the other tests.
      test_events --test_broker=test_broker broker_cli

    finally:
      network.close
      network = null

// TODO(kasper): We should probably pipe this through to the
// individual tests, but to avoid too many conflicts, I'm
// hacking this through for now.
network/net.Client? := null

test_goal --test_broker/TestBroker broker_cli/broker.BrokerCli:
  test_broker.with_service: | broker_service/broker.BrokerService |
    test_goal broker_cli broker_service


test_goal broker_cli/broker.BrokerCli broker_service/broker.BrokerService:
  3.repeat: | test_iteration |
    if test_iteration == 2:
      // Send a config update while the service is not connected.
      broker_cli.update_goal --device_id=DEVICE1.id: | device/DeviceDetailed |
        if test_iteration == 1:
          expect_equals "succeeded 2" device.goal["test-entry"]
        device.goal["test-entry"] = "succeeded while offline"
        device.goal

    broker_service.connect --network=network --device=DEVICE1:
      if broker_cli is mqtt_broker.BrokerCliMqtt:
        (broker_cli as mqtt_broker.BrokerCliMqtt).retain_timeout_ms = 500

      event_goal/Map? := null
      exception := catch:
        event_goal = broker_service.fetch_goal --wait=(test_iteration > 0)

      if test_iteration == 0:
        // None of the brokers have sent a goal-state update yet.
        if broker_cli is mqtt_broker.BrokerCliMqtt:
          expect_equals DEADLINE_EXCEEDED_ERROR exception
        expect_null event_goal
      else if test_iteration == 1:
        expect_equals "succeeded 2" event_goal["test-entry"]
      else:
        expect_equals "succeeded while offline" event_goal["test-entry"]

      broker_cli.update_goal --device_id=DEVICE1.id: | device/DeviceDetailed |
        old := device.goal
        if test_iteration == 1:
          expect_equals "succeeded 2" old["test-entry"]
        else if test_iteration == 2:
          expect_equals "succeeded while offline" old["test-entry"]
        if test_iteration == 0 and not old:
          old = {:}
        old["test-entry"] = "succeeded 1"
        old

      event_goal = broker_service.fetch_goal --wait
      expect_equals "succeeded 1" event_goal["test-entry"]

      broker_cli.update_goal --device_id=DEVICE1.id: | device/DeviceDetailed |
        old := device.goal
        expect_equals "succeeded 1" old["test-entry"]
        old["test-entry"] = "succeeded 2"
        old

      event_goal = broker_service.fetch_goal --wait
      expect_equals "succeeded 2" event_goal["test-entry"]

test_image --test_broker/TestBroker broker_cli/broker.BrokerCli:
  test_broker.with_service: | broker_service/broker.BrokerService |
    test_image broker_cli broker_service

test_image broker_cli/broker.BrokerCli broker_service/broker.BrokerService:
  2.repeat: | iteration |
    APP_ID ::= uuid.uuid5 "app" "test-app-$iteration"
    content_32 := ?
    content_64 := ?
    if iteration == 0:
      content_32 = "test-image 32".to_byte_array
      content_64 = "test-image 64".to_byte_array
    else:
      content_32 = ("test-image 32" * 10_000).to_byte_array
      content_64 = ("test-image 64" * 10_000).to_byte_array

    broker_cli.upload_image content_32
        --organization_id=TEST_ORGANIZATION_UUID
        --app_id=APP_ID
        --word_size=32
    broker_cli.upload_image content_64
        --organization_id=TEST_ORGANIZATION_UUID
        --app_id=APP_ID
        --word_size=64

    broker_service.connect --network=network --device=DEVICE1: | resources/broker.ResourceManager |
      resources.fetch_image APP_ID:
        | reader/Reader |
          // TODO(florian): this only tests the download of the current platform. That is, on
          // a 64-bit platform, it will only download the 64-bit image. It would be good, if we could
          // also verify that the 32-bit image is correct.
          data := utils.read_all reader
          expect_bytes_equal (BITS_PER_WORD == 32 ? content_32 : content_64) data

test_firmware --test_broker/TestBroker broker_cli/broker.BrokerCli:
  test_broker.with_service: | broker_service/broker.BrokerService |
    test_firmware broker_cli broker_service

test_firmware broker_cli/broker.BrokerCli broker_service/broker.BrokerService:
  3.repeat: | iteration |
    FIRMWARE_ID ::= "test-app-$iteration"
    content := ?
    if iteration == 0:
      content = "test-firmware".to_byte_array
    else:
      content = ("test-firmware" * 10_000).to_byte_array

    chunks := ?
    if iteration <= 1:
      chunks = [content]
    else:
      chunks = []
      List.chunk_up 0 content.size 1024: | from/int to/int |
        chunks.add content[from..to]

    broker_cli.upload_firmware chunks
        --firmware_id=FIRMWARE_ID
        --organization_id=TEST_ORGANIZATION_UUID

    if broker_cli is not mqtt_broker.BrokerCliMqtt:
      // Downloading a firmware isn't implemented for the MQTT broker.
      downloaded_bytes := broker_cli.download_firmware
          --id=FIRMWARE_ID
          --organization_id=TEST_ORGANIZATION_UUID
      expect_bytes_equal content downloaded_bytes

    broker_service.connect --network=network --device=DEVICE1: | resources/broker.ResourceManager |
      data := #[]
      offsets := []
      resources.fetch_firmware FIRMWARE_ID:
        | reader/Reader offset |
          expect_equals data.size offset
          while chunk := reader.read: data += chunk
          offsets.add offset
          data.size  // Continue at data.size.

      expect_equals content data

      if broker_service is not mqtt_broker.BrokerServiceMqtt:
        // Downloading a partial firmware isn't implemented in the MQTT service.
        if offsets.size > 1:
          offset_index := offsets.size / 2
          current_offset := offsets[offset_index]
          resources.fetch_firmware FIRMWARE_ID --offset=current_offset:
            | reader/Reader offset |
              expect_equals current_offset offset
              partial_data := utils.read_all reader
              expect_bytes_equal content[current_offset..current_offset + partial_data.size] partial_data

              // If we can, advance by 3 chunks.
              if offset_index + 3 < offsets.size:
                offset_index += 3
                current_offset = offsets[offset_index]
              else:
                // Otherwise advance chunk by chunk.
                // Once we reached the end, we won't be called again.
                current_offset += partial_data.size
              // Return the new offset.
              current_offset

test_events --test_broker/TestBroker broker_cli/broker.BrokerCli:
  if broker_cli is mqtt_broker.BrokerCliMqtt:
    // The MQTT broker doesn't support getting events.
    return

  test_broker.with_service: | broker_service1/broker.BrokerService |
    test_broker.with_service: | broker_service2/broker.BrokerService |
      broker_service1.connect
          --network=network
          --device=DEVICE1
          : | resources1/broker.ResourceManager |
            broker_service2.connect
                --network=network
                --device=DEVICE2
                : | resources2/broker.ResourceManager |
                  test_events
                      test_broker
                      broker_cli
                      broker_service1
                      broker_service2
                      resources1
                      resources2

test_events
    test_broker/TestBroker
    broker_cli/broker.BrokerCli
    broker_service1/broker.BrokerService
    broker_service2/broker.BrokerService
    resources1/broker.ResourceManager
    resources2/broker.ResourceManager:

  // Relies on the fact that the goal-test was run earlier.
  // It's not super easy to generate 'get-goal' events, so we rely
  // on the previous tests to do that for us.

  if broker_cli is BrokerCliSupabase:
    // Supabase services poll for the goals, which lead to events.
    events := broker_cli.get_events
        --device_ids=[DEVICE1.id]
        --types=["get-goal"]
        --limit=1000
    expect (events.contains DEVICE1.id)
    expect_not events[DEVICE1.id].is_empty

  test_broker.backdoor.clear_events

  start := Time.now
  events := broker_cli.get_events --device_ids=[DEVICE1.id] --types=["test-event"]
  expect_not (events.contains DEVICE1.id)

  events = broker_cli.get_events --device_ids=[DEVICE1.id, DEVICE2.id] --types=["test-event"]
  expect_not (events.contains DEVICE1.id)
  expect_not (events.contains DEVICE2.id)

  total_events1 := 0
  resources1.report_event --type="test-event" "test-data"
  total_events1++

  2.repeat:
    device_ids := it == 0 ? [DEVICE1.id] : [DEVICE1.id, DEVICE2.id]
    events = broker_cli.get_events
        --device_ids=device_ids
        --types=["test-event"]
    expect (events.contains DEVICE1.id)
    expect_equals 1 events[DEVICE1.id].size
    event/Event := events[DEVICE1.id][0]
    expect_equals "test-data" event.data
    expect start <= event.timestamp <= Time.now

    // Test the since parameter.
    now := Time.now
    events = broker_cli.get_events
        --device_ids=device_ids
        --types=["test-event"]
        --since=now
    expect_not (events.contains DEVICE1.id)

  10.repeat:
    resources1.report_event --type="test-event2" "test-data-$it"
    total_events1++
    resources2.report_event --type="test-event2" "test-data-$it"

  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --limit=100
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect_equals 10 events[DEVICE1.id].size
  expect_equals 10 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected_suffix := 9
  events[DEVICE1.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--
  expected_suffix = 9
  events[DEVICE2.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--

  // Limit to 5 per device.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --limit=5
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect_equals 5 events[DEVICE1.id].size
  expect_equals 5 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected_suffix = 9
  events[DEVICE1.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--
  expected_suffix = 9
  events[DEVICE2.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--

  // 5 more events for device2.
  5.repeat:
    resources2.report_event --type="test-event2" "test-data-$(it + 10)"

  // Limit to 20 per device.
  // Device 1 should have 10 events, device 2 should have 15 events.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --limit=20
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect_equals 10 events[DEVICE1.id].size
  expect_equals 15 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected_suffix = 9
  events[DEVICE1.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--
  expected_suffix = 14
  events[DEVICE2.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--

  // Make sure we test one of the most common use cases: getting just one event.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --limit=1
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect_equals 1 events[DEVICE1.id].size
  expect_equals 1 events[DEVICE2.id].size
  expect_equals "test-data-9" events[DEVICE1.id][0].data
  expect_equals "test-data-14" events[DEVICE2.id][0].data

  checkpoint := Time.now

  // Add 5 more events for both.
  5.repeat:
    resources1.report_event --type="test-event2" "test-data-$(it + 20)"
    total_events1++
    resources2.report_event --type="test-event2" "test-data-$(it + 20)"

  // Limit to events since 'checkpoint'.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --since=checkpoint
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect_equals 5 events[DEVICE1.id].size
  expect_equals 5 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected_suffix = 24
  events[DEVICE1.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--
  expected_suffix = 24
  events[DEVICE2.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--

  // Limit to events since 'checkpoint' and limit to 3.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --since=checkpoint
      --limit=3
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect_equals 3 events[DEVICE1.id].size
  expect_equals 3 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected_suffix = 24
  events[DEVICE1.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--
  expected_suffix = 24
  events[DEVICE2.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--

  // Limit to events since 'checkpoint' and limit to 10.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --since=checkpoint
      --limit=10
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect_equals 5 events[DEVICE1.id].size
  expect_equals 5 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected_suffix = 24
  events[DEVICE1.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--
  expected_suffix = 24
  events[DEVICE2.id].do: | event/Event |
    expect_equals "test-data-$expected_suffix" event.data
    expected_suffix--

  // Add 5 events for different types.
  5.repeat:
    resources1.report_event --type="test-event3" "test-data-$(it + 30)"
    total_events1++
    resources1.report_event --type="test-event4" "test-data-$(it + 40)"
    total_events1++
    resources2.report_event --type="test-event3" "test-data-$(it + 30)"
    resources2.report_event --type="test-event4" "test-data-$(it + 40)"

  // Get events for type 3 and 4.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id]
      --types=["test-event3", "test-event4"]
  expect (events.contains DEVICE1.id)
  expect_equals 10 events[DEVICE1.id].size
  // Events must come in reverse chronological order.
  expected_suffix3 := 34
  expected_suffix4 := 44
  expect4 := true
  events[DEVICE1.id].do: | event/Event |
    if expect4:
      expect_equals "test-data-$expected_suffix4" event.data
      expected_suffix4--
    else:
      expect_equals "test-data-$expected_suffix3" event.data
      expected_suffix3--
    expect4 = not expect4

  // Same for both devices at the same time.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event3", "test-event4"]
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect_equals 10 events[DEVICE1.id].size
  expect_equals 10 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  2.repeat:
    device := it == 0 ? DEVICE1 : DEVICE2
    expected_suffix3 = 34
    expected_suffix4 = 44
    expect4 = true
    events[device.id].do: | event/Event |
      if expect4:
        expect_equals "test-data-$expected_suffix4" event.data
        expected_suffix4--
      else:
        expect_equals "test-data-$expected_suffix3" event.data
        expected_suffix3--
      expect4 = not expect4

  // Get all events for device 1.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id]
      --limit=1000
  expect (events.contains DEVICE1.id)
  expect_equals total_events1 events[DEVICE1.id].size

  // Only get the last event for device 1.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id]
      --limit=1
  expect (events.contains DEVICE1.id)
  expect_equals 1 events[DEVICE1.id].size
  expect_equals "test-data-44" events[DEVICE1.id][0].data

  // Updating the state of a device automatically inserts an event.
  resources1.report_state { "entry": "test-state-1" }
  total_events1++

  // Get all events for device 1 again.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id]
      --limit=1000
  expect (events.contains DEVICE1.id)
  expect_equals total_events1 events[DEVICE1.id].size
  expect_equals "update-state" events[DEVICE1.id][0].type
