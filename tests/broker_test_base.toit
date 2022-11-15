// Copyright (C) 2022 Toitware ApS. All rights reserved.

import expect show *
import log
import monitor
import reader show SizedReader
import artemis.cli.broker
import artemis.service.broker as broker
import artemis.cli.brokers.mqtt.base as mqtt_broker
import artemis.service.brokers.mqtt.synchronize as mqtt_broker

import .brokers
import .utils

run_test broker_id/string:
  with_broker broker_id: | logger name broker_cli broker_service |
    run_test logger name broker_cli broker_service

run_test
    logger/log.Logger
    broker_name/string
    broker_cli/broker.BrokerCli
    broker_service/broker.BrokerService:

  test_image broker_cli broker_service
  test_firmware broker_cli broker_service
  test_config broker_cli broker_service

class TestEventHandler implements broker.EventHandler:
  events := []
  channel := monitor.Channel 10

  handle_update_config new_config/Map? resources/broker.ResourceManager:
    events.add ["update_config", new_config]
    channel.send "update_config"

  handle_nop:
    events.add ["nop"]
    channel.send "nop"

test_config broker_cli/broker.BrokerCli broker_service/broker.BrokerService:
  DEVICE_ID ::= "test-id-config"
  3.repeat: | test_iteration |
    test_handler := TestEventHandler
    if test_iteration == 2:
      // Send a config update while the service is not connected.
      broker_cli.device_update_config --device_id=DEVICE_ID: | old |
        if test_iteration == 1:
          expect_equals "succeeded 2" old["test-entry"]
        old["test-entry"] = "succeeded while offline"
        old

    broker_service.connect --device_id=DEVICE_ID --callback=test_handler:
      event_type := null
      if broker_cli is not mqtt_broker.BrokerCliMqtt:
        // The MQTT broker only sends a first config event when the CLI updates
        // the config. All others send it as soon as the service connects.
        // We need to wait for this initial configuration, so that the test isn't
        // flaky. Otherwise, the CLI could send an update before the service
        // connects, thus not sending the initial empty config.
        event_type = test_handler.channel.receive
      else:
        (broker_cli as mqtt_broker.BrokerCliMqtt).retain_timeout_ms = 500

      broker_cli.device_update_config --device_id=DEVICE_ID: | old |
        if test_iteration == 1:
          expect_equals "succeeded 2" old["test-entry"]
        else if test_iteration == 2:
          expect_equals "succeeded while offline" old["test-entry"]
        old["test-entry"] = "succeeded 1"
        old

      if broker_cli is mqtt_broker.BrokerCliMqtt:
        event_type = test_handler.channel.receive

      if test_iteration == 0:
        expect_equals "update_config" event_type
        event_value := test_handler.events[0]
        expect_equals "update_config" event_value[0]
        event_config := event_value[1]
        expect_not (event_config.contains "test-entry")
      else if test_iteration == 1:
        if event_type == "nop":
          // The MQTT broker doesn't send a config update when it can tell that
          // the configuration hasn't changed in the meantime.
          expect broker_cli is mqtt_broker.BrokerCliMqtt
        else:
          expect_equals "update_config" event_type
          event_value := test_handler.events[0]
          expect_equals "update_config" event_value[0]
          event_config := event_value[1]
          expect_equals "succeeded 2" event_config["test-entry"]
      else:
        expect_equals "update_config" event_type
        event_value := test_handler.events[0]
        expect_equals "update_config" event_value[0]
        event_config := event_value[1]
        expect_equals "succeeded while offline" event_config["test-entry"]

      event_type = test_handler.channel.receive
      expect_equals "update_config" event_type
      event_value := test_handler.events[1]
      expect_equals "update_config" event_value[0]
      event_config := event_value[1]
      expect_equals "succeeded 1" event_config["test-entry"]

      broker_cli.device_update_config --device_id=DEVICE_ID: | old |
        expect_equals "succeeded 1" old["test-entry"]
        old["test-entry"] = "succeeded 2"
        old

      event_type = test_handler.channel.receive
      expect_equals "update_config" event_type
      event_value = test_handler.events[2]
      expect_equals "update_config" event_value[0]
      event_config = event_value[1]
      expect_equals "succeeded 2" event_config["test-entry"]

      expect_equals 0 test_handler.channel.size

  print "done"


test_image broker_cli/broker.BrokerCli broker_service/broker.BrokerService:
  DEVICE_ID ::= "test-id-upload-image"

  2.repeat: | iteration |
    APP_ID ::= "test-app-$iteration"
    content_32 := ?
    content_64 := ?
    if iteration == 0:
      content_32 = "test-image 32".to_byte_array
      content_64 = "test-image 64".to_byte_array
    else:
      content_32 = ("test-image 32" * 10_000).to_byte_array
      content_64 = ("test-image 64" * 10_000).to_byte_array

    broker_cli.upload_image --app_id=APP_ID --bits=32 content_32
    broker_cli.upload_image --app_id=APP_ID --bits=64 content_64

    test_handler := TestEventHandler
    broker_service.connect --device_id=DEVICE_ID --callback=test_handler: | resources/broker.ResourceManager |
      resources.fetch_image APP_ID: | reader/SizedReader |
        // TODO(florian): this only tests the download of the current platform. That is, on
        // a 64-bit platform, it will only download the 64-bit image. It would be good, if we could
        // also verify that the 32-bit image is correct.
        data := #[]
        while chunk := reader.read: data += chunk
        expect_bytes_equal (BITS_PER_WORD == 32 ? content_32 : content_64) data

test_firmware broker_cli/broker.BrokerCli broker_service/broker.BrokerService:
  DEVICE_ID ::= "test-id-upload-firmware"

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

    broker_cli.upload_firmware --firmware_id=FIRMWARE_ID chunks

    if broker_cli is not mqtt_broker.BrokerCliMqtt:
      // Downloading a firmware isn't implemented for the MQTT broker.
      downloaded_bytes := broker_cli.download_firmware --id=FIRMWARE_ID
      expect_bytes_equal content downloaded_bytes

    test_handler := TestEventHandler
    broker_service.connect --device_id=DEVICE_ID --callback=test_handler: | resources/broker.ResourceManager |
      data := #[]
      offsets := []
      resources.fetch_firmware FIRMWARE_ID: | reader/SizedReader offset |
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
          resources.fetch_firmware FIRMWARE_ID --offset=current_offset: | reader/SizedReader offset |
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
