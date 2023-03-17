// Copyright (C) 2022 Toitware ApS. All rights reserved.

// ARTEMIS_TEST_FLAGS: BROKER

import expect show *
import log
import monitor
import reader show SizedReader
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
  run_test broker_type

run_test broker_type/string:
  with_brokers --type=broker_type: | logger name broker_cli broker_service |
    run_test logger name broker_cli broker_service

run_test
    logger/log.Logger
    broker_name/string
    broker_cli/broker.BrokerCli
    broker_service/broker.BrokerService:

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


  test_image broker_cli broker_service
  test_firmware broker_cli broker_service
  test_goal broker_cli broker_service
  test_events broker_cli broker_service

class TestEvent:
  type/string
  value/any

  constructor .type .value=null:

class TestEventHandler implements broker.EventHandler:
  channel := monitor.Channel 10

  handle_goal goal/Map? resources/broker.ResourceManager:
    channel.send (TestEvent "update_goal" goal)

  handle_nop:
    channel.send (TestEvent "nop")

test_goal broker_cli/broker.BrokerCli broker_service/broker.BrokerService:
  3.repeat: | test_iteration |
    test_handler := TestEventHandler
    if test_iteration == 2:
      // Send a config update while the service is not connected.
      broker_cli.update_goal --device_id=DEVICE1.id: | device/DeviceDetailed |
        if test_iteration == 1:
          expect_equals "succeeded 2" device.goal["test-entry"]
        device.goal["test-entry"] = "succeeded while offline"
        device.goal

    broker_service.connect --device=DEVICE1 --callback=test_handler:
      event/TestEvent? := null

      if broker_cli is mqtt_broker.BrokerCliMqtt:
        (broker_cli as mqtt_broker.BrokerCliMqtt).retain_timeout_ms = 500

      // Tell the broker that we're idle, so it can do its thing.
      broker_service.on_idle

      // In the first iteration none of the brokers have a goal state yet.
      // In the second iteration they already have a goal state.
      if broker_cli is not mqtt_broker.BrokerCliMqtt and test_iteration != 0:
        // All brokers, except the MQTT broker, immediately send a first initial
        // goal as soon as the service connects if they have a goal state.
        // We need to wait for this initial goal state, so that the test isn't
        // flaky. Otherwise, the CLI could send an update before the service
        // connects, thus not sending the initial empty goal state.
        event = test_handler.channel.receive

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

      broker_service.on_idle

      if broker_cli is mqtt_broker.BrokerCliMqtt:
        event = test_handler.channel.receive

      mqtt_already_has_updated_goal := false
      if test_iteration == 0:
        // None of the brokers except MQTT have sent a goal-state update yet.
        if broker_cli is mqtt_broker.BrokerCliMqtt:
          expect_equals "update_goal" event.type
          event_goal := event.value
          // When the CLI updates the goal state, it sends two goal revisions in
          // rapid succession.
          // The service might not even see the first one.
          mqtt_already_has_updated_goal = event_goal != null
      else if test_iteration == 1:
        if event.type == "nop":
          // The MQTT broker doesn't send a goal state update when it can tell that
          // the goal state hasn't changed in the meantime.
          expect broker_cli is mqtt_broker.BrokerCliMqtt
        else:
          expect_equals "update_goal" event.type
          event_goal := event.value
          expect_equals "succeeded 2" event_goal["test-entry"]
      else:
        expect_equals "update_goal" event.type
        event_goal := event.value
        expect_equals "succeeded while offline" event_goal["test-entry"]

      broker_service.on_idle
      if not mqtt_already_has_updated_goal:
        event = test_handler.channel.receive

      if test_iteration == 0:
        // The broker is allowed to send 'null' goals, indicating that
        // the device should stick with its current firmware state.
        // Skip them.
        while event.value == null:
          broker_service.on_idle
          event = test_handler.channel.receive
      expect_equals "update_goal" event.type
      event_goal := event.value
      expect_equals "succeeded 1" event_goal["test-entry"]

      broker_cli.update_goal --device_id=DEVICE1.id: | device/DeviceDetailed |
        old := device.goal
        expect_equals "succeeded 1" old["test-entry"]
        old["test-entry"] = "succeeded 2"
        old

      broker_service.on_idle
      event = test_handler.channel.receive
      expect_equals "update_goal" event.type
      event_goal = event.value
      expect_equals "succeeded 2" event_goal["test-entry"]

      expect_equals 0 test_handler.channel.size

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

    test_handler := TestEventHandler
    broker_service.connect --device=DEVICE1 --callback=test_handler: | resources/broker.ResourceManager |
      resources.fetch_image APP_ID:
        | reader/SizedReader |
          // TODO(florian): this only tests the download of the current platform. That is, on
          // a 64-bit platform, it will only download the 64-bit image. It would be good, if we could
          // also verify that the 32-bit image is correct.
          data := #[]
          while chunk := reader.read: data += chunk
          expect_bytes_equal (BITS_PER_WORD == 32 ? content_32 : content_64) data

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

    test_handler := TestEventHandler
    broker_service.connect --device=DEVICE1 --callback=test_handler: | resources/broker.ResourceManager |
      data := #[]
      offsets := []
      resources.fetch_firmware FIRMWARE_ID:
        | reader/SizedReader offset |
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
            | reader/SizedReader offset |
              expect_equals current_offset offset
              partial_data := #[]
              while chunk := reader.read: partial_data += chunk
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

test_events broker_cli/broker.BrokerCli broker_service/broker.BrokerService:
  if broker_cli is mqtt_broker.BrokerCliMqtt:
    // The MQTT broker doesn't support getting events.
    return

  broker_service.connect
      --device=DEVICE1
      --callback=TestEventHandler: | resources1/broker.ResourceManager |
    broker_service.connect
        --device=DEVICE2
        --callback=TestEventHandler: | resources2/broker.ResourceManager |
      test_events broker_cli resources1 resources2

test_events
    broker_cli/broker.BrokerCli
    resources1/broker.ResourceManager
    resources2/broker.ResourceManager:
  start := Time.now
  events := broker_cli.get_events --device_ids=[DEVICE1.id] --type="test-event"
  expect_not (events.contains DEVICE1.id)

  events = broker_cli.get_events --device_ids=[DEVICE1.id, DEVICE2.id] --type="test-event"
  expect_not (events.contains DEVICE1.id)
  expect_not (events.contains DEVICE2.id)

  resources1.report_event --type="test-event" "test-data"

  2.repeat:
    device_ids := it == 0 ? [DEVICE1.id] : [DEVICE1.id, DEVICE2.id]
    events = broker_cli.get_events
        --device_ids=device_ids
        --type="test-event"
    expect (events.contains DEVICE1.id)
    expect_equals 1 events[DEVICE1.id].size
    event/Event := events[DEVICE1.id][0]
    expect_equals "test-data" event.data
    expect start <= event.timestamp <= Time.now

    // Test the since parameter.
    now := Time.now
    events = broker_cli.get_events
        --device_ids=device_ids
        --type="test-event"
        --since=now
    expect_not (events.contains DEVICE1.id)

  10.repeat:
    resources1.report_event --type="test-event2" "test-data-$it"
    resources2.report_event --type="test-event2" "test-data-$it"

  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --type="test-event2"
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
      --type="test-event2"
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
      --type="test-event2"
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
      --type="test-event2"
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
    resources2.report_event --type="test-event2" "test-data-$(it + 20)"

  // Limit to events since 'checkpoint'.
  events = broker_cli.get_events
      --device_ids=[DEVICE1.id, DEVICE2.id]
      --type="test-event2"
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
      --type="test-event2"
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
      --type="test-event2"
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
