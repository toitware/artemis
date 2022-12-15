// Copyright (C) 2022 Toitware ApS.

import encoding.tison
import expect show *
import monitor

import .brokers

import artemis.service
import artemis.service.check_in show check_in_setup
import artemis.service.device show Device
import artemis.shared.server_config show ServerConfig
import ..tools.http_servers.artemis_server
import .utils

// Note that the service has global state (when to check in, ...).
// Calling `run_test` twice from the same test will thus not work.
run_test --insert_device/bool:
  device_id := "test-device-check-in"
  device := Device --id=device_id --firmware="foo"
  with_http_broker: | broker_config/ServerConfig |
    with_http_artemis_server: | server/HttpArtemisServer artemis_server_config/ServerConfig |
      if insert_device:
        server.devices[device_id] = DeviceEntry device_id
            --alias="test-alias"
            --organization_id="test-organization"

      checkin_latch := monitor.Latch
      server.listeners.add:: | state/string command/string data/any |
        if command == "check-in" and state != "pre":
          checkin_latch.set [state, data]

      assets := {
        "artemis.broker": tison.encode (artemis_server_config.to_json --certificate_deduplicator=: it)
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
