// Copyright (C) 2022 Toitware ApS.

// TEST_FLAGS: --insert-device --no-insert-device

import encoding.tison
import expect show *
import monitor

import .artemis_server
import .brokers
import .utils

import artemis.service
import artemis.service.check_in show check_in_setup
import artemis.service.device show Device
import artemis.shared.server_config show ServerConfig
import ..tools.http_servers.artemis_server

main args:
  if args.is_empty: args=["--insert-device"]
  run_test --insert_device=(args[0] == "--insert-device")

// Note that the service has global state (when to check in, ...).
// Calling `run_test` twice from the same test will thus not work.
run_test --insert_device/bool:
  device_id := "test-device-check-in"
  device := Device --id=device_id
      --organization_id=TEST_ORGANIZATION_UUID
      --firmware_state={
        "firmware": encoded_firmware --device_id=device_id,
      }
  with_http_broker: | broker_config/ServerConfig |
    with_http_artemis_server: | artemis_server/TestArtemisServer |
      backdoor := artemis_server.backdoor as ToitHttpBackdoor
      server := backdoor.server
      if insert_device:
        server.devices[device_id] = DeviceEntry device_id
            --alias="test-alias"
            --organization_id="test-organization"

      checkin_latch := monitor.Latch
      server.listeners.add:: | state/string command/string data/any |
        if command == "check-in" and state != "pre":
          checkin_latch.set [state, data]

      artemis_json := artemis_server.server_config.to_json
          --der_serializer=: throw "UNIMPLEMENTED"
      encoded_artemis := tison.encode artemis_json
      assets := {
        "artemis.broker": encoded_artemis
      }
      device_map := {
        "hardware_id": device_id
      }
      check_in_setup assets device_map

      artemis_task := task::
        service.run_artemis device broker_config --no-start_ntp

      checkin_data := checkin_latch.get
      if not insert_device:
        // The device is not known.
        expect_equals "error" checkin_data[0]
        expect_equals "Device not found" checkin_data[1]
      else:
        expect_equals "post" checkin_data[0]

      artemis_task.cancel
