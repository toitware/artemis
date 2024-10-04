// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show *
import encoding.json
import encoding.ubjson
import encoding.base64
import encoding.tison
import system.assets
import uuid show Uuid

import watchdog.provider as watchdog
import watchdog show Watchdog WatchdogServiceClient

import .null-pin-trigger
import .null-watchdog
import ..utils show decode-server-config
import ..service show run-artemis
import ..device
import ..storage show Storage
import ..watchdog
import ...cli.artemis show Artemis
import ...cli.cache as cli
import ...cli.device as artemis-device
import ...cli.firmware as fw
import ...cli.pod
import ...cli.sdk
import ...cli.utils

main arguments:
  root-cmd := Command "artemis-service"
      --options=[
        Option "pod"
            --type="file"
            --required,
        Option "identity"
            --type="file"
            --required,
      ]
      --run=:: | invocation/Invocation |
        run-host
          --pod-path=invocation["pod"]
          --identity-path=invocation["identity"]
          --cli=invocation.cli
  root-cmd.run arguments

run-host --pod-path/string --identity-path/string --cli/Cli -> none:
  with-tmp-directory: | tmp-dir |
    pod := Pod.parse pod-path --tmp-directory=tmp-dir --cli=cli
    run-host --pod=pod --identity-path=identity-path --cli=cli

run-host --pod/Pod --identity-path/string --cli/Cli -> none:
  watchdog-provider := watchdog.WatchdogServiceProvider --system-watchdog=NullWatchdog
  watchdog-provider.install

  client/WatchdogServiceClient := (WatchdogServiceClient).open as WatchdogServiceClient
  watchdog := client.create "toit.io/artemis"
  watchdog.start --s=WATCHDOG-TIMEOUT-S

  identity := read-base64-ubjson identity-path
  identity["artemis.broker"] = tison.encode identity["artemis.broker"]
  identity["broker"] = tison.encode identity["broker"]
  device-identity := identity["artemis.device"]

  artemis-device := artemis-device.Device
      --hardware-id=Uuid.parse device-identity["hardware_id"]
      --organization-id=Uuid.parse device-identity["organization_id"]
      --id=Uuid.parse device-identity["device_id"]

  firmware := fw.Firmware
      --pod=pod
      --device=artemis-device
      --cli=cli
  encoded-firmware-description := firmware.encoded

  sdk-version := pod.sdk-version
  sdk := get-sdk sdk-version --cli=cli
  with-tmp-directory: | tmp-dir/string |
    asset-path := "$tmp-dir/artemis_asset"
    sdk.firmware-extract-container --assets
        --name="artemis"
        --envelope-path=pod.envelope-path
        --output-path=asset-path
    config-asset := sdk.assets-extract
        --name="device-config"
        --assets-path=asset-path

    config := json.decode config-asset
    config["firmware"] = encoded-firmware-description
    storage := Storage

    while true:
      device := Device
          --id=artemis-device.id
          --hardware-id=artemis-device.hardware-id
          --organization-id=artemis-device.organization-id
          --firmware-state=config
          --storage=storage
      server-config := decode-server-config "broker" identity
      sleep-duration := run-artemis
          device
          server-config
          --recovery-urls=null
          --watchdog=watchdog
          --storage=storage
          --pin-trigger-manager=NullPinTriggerManager
      sleep sleep-duration
