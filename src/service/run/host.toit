// Copyright (C) 2022 Toitware ApS. All rights reserved.

import bytes
import cli
import io

import system.assets

import encoding.json
import encoding.ubjson
import encoding.base64
import encoding.tison
import uuid

import watchdog.provider as watchdog
import watchdog show Watchdog WatchdogServiceClient

import ..utils show decode-server-config
import ..service show run-artemis
import ..check-in show check-in-setup
import ..device
import ..storage show Storage
import ..watchdog
import ...cli.artemis show Artemis
import ...cli.cache as cli
import ...cli.device as artemis-device
import ...cli.firmware as fw
import ...cli.pod
import ...cli.sdk
import ...cli.ui show Ui ConsoleUi
import ...cli.utils

main arguments:
  cache := cli.Cache --app-name="artemis"
  root-cmd := cli.Command "root"
      --options=[
        cli.OptionString "pod"
            --type="file"
            --required,
        cli.OptionString "identity"
            --type="file"
            --required,
      ]
      --run=:: run-host
          --pod-path=it["pod"]
          --identity-path=it["identity"]
          --cache=cache
  root-cmd.run arguments

run-host --pod-path/string --identity-path/string --cache/cli.Cache -> none:
  ui := ConsoleUi
  with-tmp-directory: | tmp-dir |
    pod := Pod.parse pod-path --tmp-directory=tmp-dir --ui=ui
    run-host --pod=pod --identity-path=identity-path --cache=cache

/**
A system watchdog that ignores all calls to it.
*/
class NullWatchdog implements watchdog.SystemWatchdog:
  start --ms/int:
  feed -> none:
  stop -> none:
  reboot -> none:

run-host --pod/Pod --identity-path/string --cache/cli.Cache -> none:
  watchdog-provider := watchdog.WatchdogServiceProvider
      --system-watchdog=NullWatchdog
  watchdog-provider.install

  client/WatchdogServiceClient := (WatchdogServiceClient).open as WatchdogServiceClient
  watchdog := client.create "toit.io/artemis"
  watchdog.start --s=WATCHDOG-TIMEOUT-S

  identity := read-base64-ubjson identity-path
  identity["artemis.broker"] = tison.encode identity["artemis.broker"]
  identity["broker"] = tison.encode identity["broker"]
  device-identity := identity["artemis.device"]

  artemis-device := artemis-device.Device
      --hardware-id=uuid.parse device-identity["hardware_id"]
      --organization-id=uuid.parse device-identity["organization_id"]
      --id=uuid.parse device-identity["device_id"]

  firmware := fw.Firmware
      --pod=pod
      --device=artemis-device
      --cache=cache
  encoded-firmware-description := firmware.encoded

  sdk-version := pod.sdk-version
  sdk := get-sdk sdk-version --cache=cache
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
    storage := StorageHost

    while true:
      device := Device
          --id=artemis-device.id
          --hardware-id=artemis-device.hardware-id
          --organization-id=artemis-device.organization-id
          --firmware-state=config
          --storage=storage
      check-in-setup --assets=identity --device=device
      server-config := decode-server-config "broker" identity
      sleep-duration := run-artemis
          device
          server-config
          --watchdog=watchdog
          --storage=storage
      sleep sleep-duration
      print

class StorageHost extends Storage:
  container-list-images -> List:
    return []

  container-write-image --id/uuid.Uuid --size/int --reader/io.Reader -> uuid.Uuid:
    throw "UNIMPLEMENTED"
