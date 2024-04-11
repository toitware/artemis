// Copyright (C) 2022 Toitware ApS.

// TODO(florian): these are now ignored.
// TEST_FLAGS: --insert-device --no-insert-device

import encoding.tison
import expect show *
import monitor
import watchdog.provider as watchdog
import watchdog show WatchdogServiceClient

import .artemis-server
import .broker show with-http-broker TestBroker
import .utils

import artemis.service
import artemis.service.check-in show check-in-setup
import artemis.service.device show Device
import artemis.service.storage show Storage
import artemis.shared.server-config show ServerConfig
import artemis.shared.constants show COMMAND-CHECK-IN_
import artemis.service.run.host show NullWatchdog
import ..tools.http-servers.artemis-server

main args:
  watchdog-provider := watchdog.WatchdogServiceProvider --system-watchdog=NullWatchdog
  watchdog-provider.install

  if args.is-empty: args=["--insert-device"]
  run-test --insert-device=(args[0] == "--insert-device")

  watchdog-provider.uninstall

// Note that the service has global state (when to check in, ...).
// Calling `run_test` twice from the same test will thus not work.
run-test --insert-device/bool:
  device-id := random-uuid
  device := Device
      --id=device-id
      --hardware-id=device-id
      --organization-id=TEST-ORGANIZATION-UUID
      --firmware-state={
        "firmware": build-encoded-firmware --device-id=device-id,
      }
      --storage=Storage
  with-http-broker: | test-broker/TestBroker |
    broker-config := test-broker.server-config
    with-http-artemis-server: | artemis-server/TestArtemisServer |
      backdoor := artemis-server.backdoor as ToitHttpBackdoor
      server := backdoor.server
      if insert-device:
        server.devices["$device-id"] = DeviceEntry "$device-id"
            --alias="test-alias"
            --organization-id="test-organization"

      checkin-latch := monitor.Latch
      server.listeners.add:: | state/string command/int data/any |
        if command == COMMAND-CHECK-IN_ and state != "pre":
          checkin-latch.set [state, data]

      artemis-json := artemis-server.server-config.to-json
          --der-serializer=: throw "UNIMPLEMENTED"
      encoded-artemis := tison.encode artemis-json
      assets := {
        "artemis.broker": encoded-artemis
      }
      check-in-setup --assets=assets --device=device

      client/WatchdogServiceClient := (WatchdogServiceClient).open as WatchdogServiceClient
      watchdog := client.create "toit.io/artemis"
      watchdog.start --s=10

      artemis-task := task::
        service.run-artemis device broker-config --watchdog=watchdog --no-start-ntp

      checkin-data := checkin-latch.get
      if not insert-device:
        // The device is not known.
        expect-equals "error" checkin-data[0]
        expect-equals "Device not found" checkin-data[1]
      else:
        expect-equals "post" checkin-data[0]



      artemis-task.cancel
