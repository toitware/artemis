// Copyright (C) 2023 Toitware ApS.

import encoding.json

import cli
import artemis.shared.server-config
import artemis.service.service
import artemis.service.device as service
import artemis.cli.utils show OptionUuid
import artemis.service.storage show Storage
import artemis.service.run.null-pin-trigger show NullPinTriggerManager
import artemis.service.run.null-watchdog show NullWatchdog
import uuid
import watchdog.provider as watchdog
import watchdog show WatchdogServiceClient

main args:
  cmd := cli.Command "root"
    --options=[
      cli.Option "broker-config-json" --required,
      OptionUuid "alias-id" --required,
      OptionUuid "hardware-id" --required,
      OptionUuid "organization-id" --required,
      cli.Option "encoded-firmware" --required,
    ]
    --run=::
      run
          --alias-id=it["alias-id"]
          --hardware-id=it["hardware-id"]
          --organization-id=it["organization-id"]
          --encoded-firmware=it["encoded-firmware"]
          --broker-config-json=it["broker-config-json"]

  cmd.run args

run
    --alias-id/uuid.Uuid
    --hardware-id/uuid.Uuid
    --organization-id/uuid.Uuid
    --encoded-firmware/string
    --broker-config-json/string:
  (watchdog.WatchdogServiceProvider --system-watchdog=NullWatchdog).install

  decoded-broker-config := json.parse broker-config-json
  broker-config := server-config.ServerConfig.from-json
      "device-broker"
      decoded-broker-config
      --der-deserializer=: unreachable

  storage := Storage
  device := service.Device
      --id=alias-id
      --hardware-id=hardware-id
      --organization-id=organization-id
      --firmware-state={
        "firmware": encoded-firmware,
      }
      --storage=storage
  client/WatchdogServiceClient := (WatchdogServiceClient).open as WatchdogServiceClient
  while true:
    watchdog := client.create "toit.io/artemis"
    watchdog.start --s=10
    sleep-duration := service.run-artemis
        device
        broker-config
        --no-start-ntp
        --watchdog=watchdog
        --storage=storage
        --pin-trigger-manager=NullPinTriggerManager
    sleep sleep-duration
    watchdog.stop
    watchdog.close

