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
import artemis.cli.brokers.http.base as http-broker
import supabase
import supabase.auth as supabase
import system
import artemis.shared.utils
import uuid

import .artemis-server
  show
    with-artemis-server
    TestArtemisServer
    SupabaseBackdoor
import .broker
import .utils

// When running the supabase test we need valid device ids
// that are not already in the database.
DEVICE1 ::= Device
    --id=random-uuid
    --hardware-id=random-uuid
    --organization-id=TEST-ORGANIZATION-UUID
    --firmware-state={:}
DEVICE2 ::= Device
    --id=random-uuid
    --hardware-id=random-uuid
    --organization-id=TEST-ORGANIZATION-UUID
    --firmware-state={:}

main args:
  broker-type := broker-type-from-args args
  with-broker --args=args --type=broker-type: | test-broker/TestBroker |
    run-test broker-type test-broker --args=args

run-test
    --args/List
    broker-name/string
    test-broker/TestBroker:

  // We are going to reuse the cli for all tests (and only authenticate once).
  // However, we will need multiple services.
  test-broker.with-cli: | broker-cli/broker.BrokerCli |
    // Make sure we are authenticated.
    broker-cli.ensure-authenticated:
      broker-cli.sign-in --email=TEST-EXAMPLE-COM-EMAIL --password=TEST-EXAMPLE-COM-PASSWORD

    if broker-name == "supabase-local-artemis":
      // Make sure the device is in the database.
      with-artemis-server --args=args --type="supabase": | server/TestArtemisServer |
        backdoor := server.backdoor as SupabaseBackdoor
        backdoor.with-backdoor-client_: | client/supabase.Client |
          [DEVICE1, DEVICE2].do: | device/Device |
            client.rest.insert "devices" {
              "alias": "$device.id",
              "organization_id": "$device.organization-id",
            }

    [DEVICE1, DEVICE2].do: | device/Device |
      identity := {
        "device_id": "$device.id",
        "organization_id": "$device.organization-id",
        "hardware_id": "$device.hardware-id",
      }
      state := {
        "identity": identity,
      }
      broker-cli.notify-created --device-id=device.id --state=state

    network := net.open
    try:
      test-image --test-broker=test-broker broker-cli --network=network
      test-firmware --test-broker=test-broker broker-cli --network=network
      test-goal --test-broker=test-broker broker-cli --network=network
      test-state-devices --test-broker=test-broker broker-cli --network=network
      // Test the events last, as it depends on test_goal to have run.
      // It also does state updates which could interfere with the other tests,
      // like the health test.
      test-events --test-broker=test-broker broker-cli --network=network

    finally:
      network.close

test-goal --test-broker/TestBroker broker-cli/broker.BrokerCli --network/net.Client:
  test-broker.with-service: | broker-service/broker.BrokerService |
    test-goal broker-cli broker-service --network=network


test-goal broker-cli/broker.BrokerCli broker-service/broker.BrokerService --network/net.Client:
  3.repeat: | test-iteration |
    if test-iteration == 2:
      // Send a config update while the service is not connected.
      broker-cli.update-goal --device-id=DEVICE1.id: | device/DeviceDetailed |
        if test-iteration == 1:
          expect-equals "succeeded 2" device.goal["test-entry"]
        device.goal["test-entry"] = "succeeded while offline"
        device.goal

    broker-connection := broker-service.connect --network=network --device=DEVICE1
    try:
      event-goal/Map? := null
      exception := catch:
        event-goal = broker-connection.fetch-goal-state --wait=(test-iteration > 0)

      if test-iteration == 0:
        // None of the brokers have sent a goal-state update yet.
        expect-null event-goal
      else if test-iteration == 1:
        expect-equals "succeeded 2" event-goal["test-entry"]
      else:
        expect-equals "succeeded while offline" event-goal["test-entry"]

      broker-cli.update-goal --device-id=DEVICE1.id: | device/DeviceDetailed |
        old := device.goal
        if test-iteration == 1:
          expect-equals "succeeded 2" old["test-entry"]
        else if test-iteration == 2:
          expect-equals "succeeded while offline" old["test-entry"]
        if test-iteration == 0 and not old:
          old = {:}
        old["test-entry"] = "succeeded 1"
        old

      event-goal = broker-connection.fetch-goal-state --wait
      expect-equals "succeeded 1" event-goal["test-entry"]

      broker-cli.update-goal --device-id=DEVICE1.id: | device/DeviceDetailed |
        old := device.goal
        expect-equals "succeeded 1" old["test-entry"]
        old["test-entry"] = "succeeded 2"
        old

      event-goal = broker-connection.fetch-goal-state --wait
      expect-equals "succeeded 2" event-goal["test-entry"]
    finally:
      broker-connection.close

test-image --test-broker/TestBroker broker-cli/broker.BrokerCli --network/net.Client:
  test-broker.with-service: | broker-service/broker.BrokerService |
    test-image broker-cli broker-service --network=network

test-image broker-cli/broker.BrokerCli broker-service/broker.BrokerService --network/net.Client:
  2.repeat: | iteration |
    APP-ID ::= uuid.uuid5 "app-$random" "test-app-$iteration-$Time.monotonic-us"
    content-32 := ?
    content-64 := ?
    if iteration == 0:
      content-32 = "test-image 32".to-byte-array
      content-64 = "test-image 64".to-byte-array
    else:
      content-32 = ("test-image 32" * 10_000).to-byte-array
      content-64 = ("test-image 64" * 10_000).to-byte-array

    broker-cli.upload-image content-32
        --organization-id=TEST-ORGANIZATION-UUID
        --app-id=APP-ID
        --word-size=32
    broker-cli.upload-image content-64
        --organization-id=TEST-ORGANIZATION-UUID
        --app-id=APP-ID
        --word-size=64

    broker-connection := broker-service.connect --network=network --device=DEVICE1
    try:
      broker-connection.fetch-image APP-ID:
        | reader/Reader |
          // TODO(florian): this only tests the download of the current platform. That is, on
          // a 64-bit platform, it will only download the 64-bit image. It would be good, if we could
          // also verify that the 32-bit image is correct.
          data := utils.read-all reader
          expect-bytes-equal (system.BITS-PER-WORD == 32 ? content-32 : content-64) data
    finally:
      broker-connection.close

test-firmware --test-broker/TestBroker broker-cli/broker.BrokerCli --network/net.Client:
  test-broker.with-service: | broker-service/broker.BrokerService |
    test-firmware broker-cli broker-service --network=network

test-firmware broker-cli/broker.BrokerCli broker-service/broker.BrokerService --network/net.Client:
  3.repeat: | iteration |
    FIRMWARE-ID ::= "test-app-$iteration"
    content := ?
    if iteration == 0:
      content = "test-firmware".to-byte-array
    else:
      content = ("test-firmware" * 10_000).to-byte-array

    chunks := ?
    if iteration <= 1:
      chunks = [content]
    else:
      chunks = []
      List.chunk-up 0 content.size 1024: | from/int to/int |
        chunks.add content[from..to]

    broker-cli.upload-firmware chunks
        --firmware-id=FIRMWARE-ID
        --organization-id=TEST-ORGANIZATION-UUID

    downloaded-bytes := broker-cli.download-firmware
        --id=FIRMWARE-ID
        --organization-id=TEST-ORGANIZATION-UUID
    expect-bytes-equal content downloaded-bytes

    broker-connection := broker-service.connect --network=network --device=DEVICE1
    try:
      data := #[]
      broker-connection.fetch-firmware FIRMWARE-ID:
        | reader/Reader offset |
          expect-equals data.size offset
          while chunk := reader.read: data += chunk
          data.size  // Continue at data.size.

      expect-equals content data

      if content.size > 100:
        // Test that we can fetch the firmware starting at an offset.
        current-offset := 3 * content.size / 4
        broker-connection.fetch-firmware FIRMWARE-ID --offset=current-offset:
          | reader/Reader offset |
            expect-equals current-offset offset
            partial-data := utils.read-all reader
            expect-bytes-equal content[current-offset..current-offset + partial-data.size] partial-data

            current-offset += partial-data.size
            // Return the new offset.
            current-offset
    finally:
      broker-connection.close

build-state_ device/Device token/string -> Map:
  return {
    "token": token,
    "firmware": build-encoded-firmware --device=device,
  }

test-state-devices --test-broker/TestBroker broker-cli/broker.BrokerCli --network/net.Client:
  test-broker.with-service: | broker-service/broker.BrokerService |
    test-state-devices broker-cli broker-service --network=network

test-state-devices broker-cli/broker.BrokerCli broker-service/broker.BrokerService --network/net.Client:
  broker-cli.update-goal --device-id=DEVICE1.id: | device/DeviceDetailed |
    {
      "state-test": "1234",
    }

  broker-cli.update-goal --device-id=DEVICE2.id: | device/DeviceDetailed |
    {
      "state-test": "5678",
    }

  broker-connection := broker-service.connect --network=network --device=DEVICE1
  try:
    goal-state := build-state_ DEVICE1 "goal"
    current-state := build-state_ DEVICE1 "current"
    firmware-state := build-state_ DEVICE1 "firmware"
    broker-connection.report-state {
      "goal-state": goal-state,
      "current-state":  current-state,
      "firmware-state": firmware-state,
      "pending-firmware": "pending-firmware",
      "firmware": build-encoded-firmware --device=DEVICE1
    }
  finally:
    broker-connection.close

  broker-connection = broker-service.connect --network=network --device=DEVICE2
  try:
    goal-state := build-state_ DEVICE2 "goal2"
    current-state := build-state_ DEVICE2 "current2"
    firmware-state := build-state_ DEVICE2 "firmware2"
    broker-connection.report-state {
      "goal-state": goal-state,
      "current-state":  current-state,
      "firmware-state": firmware-state,
      "pending-firmware": "pending-firmware2",
      "firmware2": build-encoded-firmware --device=DEVICE2
    }
  finally:
    broker-connection.close

  2.repeat:
    device1/DeviceDetailed := ?
    device2/DeviceDetailed := ?
    if it == 0:
      devices := broker-cli.get-devices --device-ids=[DEVICE1.id]
      expect-equals 1 devices.size
      device1 = devices[DEVICE1.id]
      devices = broker-cli.get-devices --device-ids=[DEVICE2.id]
      expect-equals 1 devices.size
      device2 = devices[DEVICE2.id]
    else:
      devices := broker-cli.get-devices --device-ids=[DEVICE1.id, DEVICE2.id]
      expect-equals 2 devices.size
      device1 = devices[DEVICE1.id]
      device2 = devices[DEVICE2.id]

      expect-equals DEVICE1.id device1.id
      expect-equals "1234" device1.goal["state-test"]
      expect-equals "firmware" device1.reported-state-firmware["token"]
      expect-equals "current" device1.reported-state-current["token"]
      expect-equals "goal" device1.reported-state-goal["token"]
      expect-equals "pending-firmware" device1.pending-firmware

      expect-equals DEVICE2.id device2.id
      expect-equals "5678" device2.goal["state-test"]
      expect-equals "firmware2" device2.reported-state-firmware["token"]
      expect-equals "current2" device2.reported-state-current["token"]
      expect-equals "goal2" device2.reported-state-goal["token"]
      expect-equals "pending-firmware2" device2.pending-firmware

test-events --test-broker/TestBroker broker-cli/broker.BrokerCli --network/net.Client:
  test-broker.with-service: | broker-service1/broker.BrokerService |
    test-broker.with-service: | broker-service2/broker.BrokerService |
      broker-connection1 := null
      broker-connection2 := null
      try:
        broker-connection1 = broker-service1.connect --network=network --device=DEVICE1
        broker-connection2 = broker-service2.connect --network=network --device=DEVICE2
        test-events
            test-broker
            broker-cli
            broker-service1
            broker-service2
            broker-connection1
            broker-connection2
      finally:
        if broker-connection2: broker-connection2.close
        if broker-connection1: broker-connection1.close

test-events
    test-broker/TestBroker
    broker-cli/broker.BrokerCli
    broker-service1/broker.BrokerService
    broker-service2/broker.BrokerService
    broker-connection1/broker.BrokerConnection
    broker-connection2/broker.BrokerConnection:

  // Relies on the fact that the goal-test was run earlier.
  // It's not super easy to generate 'get-goal' events, so we rely
  // on the previous tests to do that for us.

  // Services poll for the goals, which lead to events.
  events := broker-cli.get-events
      --device-ids=[DEVICE1.id]
      --types=["get-goal"]
      --limit=1000
  expect (events.contains DEVICE1.id)
  expect-not events[DEVICE1.id].is-empty

  test-broker.backdoor.clear-events

  start := Time.now
  events = broker-cli.get-events --device-ids=[DEVICE1.id] --types=["test-event"]
  expect-not (events.contains DEVICE1.id)

  events = broker-cli.get-events --device-ids=[DEVICE1.id, DEVICE2.id] --types=["test-event"]
  expect-not (events.contains DEVICE1.id)
  expect-not (events.contains DEVICE2.id)

  total-events1 := 0
  broker-connection1.report-event --type="test-event" "test-data"
  total-events1++

  2.repeat:
    device-ids := it == 0 ? [DEVICE1.id] : [DEVICE1.id, DEVICE2.id]
    events = broker-cli.get-events
        --device-ids=device-ids
        --types=["test-event"]
    expect (events.contains DEVICE1.id)
    expect-equals 1 events[DEVICE1.id].size
    event/Event := events[DEVICE1.id][0]
    expect-equals "test-data" event.data
    expect start <= event.timestamp <= Time.now

    // Test the since parameter.
    now := Time.now
    events = broker-cli.get-events
        --device-ids=device-ids
        --types=["test-event"]
        --since=now
    expect-not (events.contains DEVICE1.id)

  10.repeat:
    broker-connection1.report-event --type="test-event2" "test-data-$it"
    total-events1++
    broker-connection2.report-event --type="test-event2" "test-data-$it"

  events = broker-cli.get-events
      --device-ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --limit=100
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect-equals 10 events[DEVICE1.id].size
  expect-equals 10 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected-suffix := 9
  events[DEVICE1.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--
  expected-suffix = 9
  events[DEVICE2.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--

  // Limit to 5 per device.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --limit=5
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect-equals 5 events[DEVICE1.id].size
  expect-equals 5 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected-suffix = 9
  events[DEVICE1.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--
  expected-suffix = 9
  events[DEVICE2.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--

  // 5 more events for device2.
  5.repeat:
    broker-connection2.report-event --type="test-event2" "test-data-$(it + 10)"

  // Limit to 20 per device.
  // Device 1 should have 10 events, device 2 should have 15 events.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --limit=20
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect-equals 10 events[DEVICE1.id].size
  expect-equals 15 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected-suffix = 9
  events[DEVICE1.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--
  expected-suffix = 14
  events[DEVICE2.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--

  // Make sure we test one of the most common use cases: getting just one event.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --limit=1
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect-equals 1 events[DEVICE1.id].size
  expect-equals 1 events[DEVICE2.id].size
  expect-equals "test-data-9" events[DEVICE1.id][0].data
  expect-equals "test-data-14" events[DEVICE2.id][0].data

  checkpoint := Time.now

  // Add 5 more events for both.
  5.repeat:
    broker-connection1.report-event --type="test-event2" "test-data-$(it + 20)"
    total-events1++
    broker-connection2.report-event --type="test-event2" "test-data-$(it + 20)"

  // Limit to events since 'checkpoint'.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --since=checkpoint
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect-equals 5 events[DEVICE1.id].size
  expect-equals 5 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected-suffix = 24
  events[DEVICE1.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--
  expected-suffix = 24
  events[DEVICE2.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--

  // Limit to events since 'checkpoint' and limit to 3.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --since=checkpoint
      --limit=3
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect-equals 3 events[DEVICE1.id].size
  expect-equals 3 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected-suffix = 24
  events[DEVICE1.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--
  expected-suffix = 24
  events[DEVICE2.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--

  // Limit to events since 'checkpoint' and limit to 10.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event2"]
      --since=checkpoint
      --limit=10
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect-equals 5 events[DEVICE1.id].size
  expect-equals 5 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  expected-suffix = 24
  events[DEVICE1.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--
  expected-suffix = 24
  events[DEVICE2.id].do: | event/Event |
    expect-equals "test-data-$expected-suffix" event.data
    expected-suffix--

  // Add 5 events for different types.
  5.repeat:
    broker-connection1.report-event --type="test-event3" "test-data-$(it + 30)"
    total-events1++
    broker-connection1.report-event --type="test-event4" "test-data-$(it + 40)"
    total-events1++
    broker-connection2.report-event --type="test-event3" "test-data-$(it + 30)"
    broker-connection2.report-event --type="test-event4" "test-data-$(it + 40)"

  // Get events for type 3 and 4.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id]
      --types=["test-event3", "test-event4"]
  expect (events.contains DEVICE1.id)
  expect-equals 10 events[DEVICE1.id].size
  // Events must come in reverse chronological order.
  expected-suffix3 := 34
  expected-suffix4 := 44
  expect4 := true
  events[DEVICE1.id].do: | event/Event |
    if expect4:
      expect-equals "test-data-$expected-suffix4" event.data
      expected-suffix4--
    else:
      expect-equals "test-data-$expected-suffix3" event.data
      expected-suffix3--
    expect4 = not expect4

  // Same for both devices at the same time.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id, DEVICE2.id]
      --types=["test-event3", "test-event4"]
  expect (events.contains DEVICE1.id)
  expect (events.contains DEVICE2.id)
  expect-equals 10 events[DEVICE1.id].size
  expect-equals 10 events[DEVICE2.id].size
  // Events must come in reverse chronological order.
  2.repeat:
    device := it == 0 ? DEVICE1 : DEVICE2
    expected-suffix3 = 34
    expected-suffix4 = 44
    expect4 = true
    events[device.id].do: | event/Event |
      if expect4:
        expect-equals "test-data-$expected-suffix4" event.data
        expected-suffix4--
      else:
        expect-equals "test-data-$expected-suffix3" event.data
        expected-suffix3--
      expect4 = not expect4

  // Get all events for device 1.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id]
      --limit=1000
  expect (events.contains DEVICE1.id)
  expect-equals total-events1 events[DEVICE1.id].size

  // Only get the last event for device 1.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id]
      --limit=1
  expect (events.contains DEVICE1.id)
  expect-equals 1 events[DEVICE1.id].size
  expect-equals "test-data-44" events[DEVICE1.id][0].data

  // Updating the state of a device automatically inserts an event.
  broker-connection1.report-state { "entry": "test-state-1" }
  total-events1++

  // Get all events for device 1 again.
  events = broker-cli.get-events
      --device-ids=[DEVICE1.id]
      --limit=1000
  expect (events.contains DEVICE1.id)
  expect-equals total-events1 events[DEVICE1.id].size
  expect-equals "update-state" events[DEVICE1.id][0].type
