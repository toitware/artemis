// Copyright (C) 2023 Toitware ApS.

import encoding.json

import artemis.shared.server-config
import artemis.service.service
import artemis.service.device as service
import artemis.cli.utils show OptionUuid
import artemis.service.storage show Storage
import artemis.service.run.null-pin-trigger show NullPinTriggerManager
import artemis.service.run.null-watchdog show NullWatchdog
import cli
import encoding.json
import http
import net
import uuid
import watchdog.provider as watchdog
import watchdog show WatchdogServiceClient

/**
A test device.

This part of the code runs in a spawned process.
It reflects the forked part of the util's TestDevice.
*/

BACKDOOR-PREFIX ::= "Backdoor server **"
BACKDOOR-FOOTER ::= "-- BACKDOOR END --"

extract-backdoor-url bytes/ByteArray -> string:
  lines := bytes.to-string.split "\n"
  lines.filter --in-place: it.starts-with BACKDOOR-PREFIX
  if lines.size != 1: throw "Expected exactly one backdoor server line"
  return (lines[0].split "**")[1].trim

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

/**
A backdoor that lets the test reach into the device.
*/
class Backdoor:
  network_/net.Client? := null
  storage_/Storage
  device_/service.Device
  server-task_/Task? := null

  constructor --storage/Storage --device/service.Device:
    storage_ = storage
    device_ = device

  close:
    if server-task_:
      server-task_.cancel
      server-task_ = null
    if network_:
      network_.close
      network_ = null

  start:
    if network_: throw "Backdoor already started"
    network_ = net.open
    // Listen on a free port.
    tcp-socket := network_.tcp-listen 0
    print "$BACKDOOR-PREFIX http://localhost:$tcp-socket.local-address.port"
    print BACKDOOR-FOOTER
    server := http.Server
    server-task_ = task::
      server.listen tcp-socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
        resource := request.query.resource
        if resource == "/device-id":
          handle-device-id-request_ resource request writer
        else if resource.starts-with "/storage/":
          handle-storage-request_ resource request writer
        else:
          throw "unknown resource"
        writer.close

  handle-device-id-request_ resource/string request/http.RequestIncoming writer/http.ResponseWriter:
    writer.out.write (json.encode "$device_.id")

  handle-storage-request_ resource/string request/http.RequestIncoming writer/http.ResponseWriter:
    segments := resource.split "/"
    if segments.size != 4: throw "invalid resource"
    scheme := segments[2]
    key := segments[3]
    if request.method == "GET":
      writer.headers.add "Content-Type" "application/json"
      value := scheme == "ram" ? storage_.ram-load key : storage_.flash-load key
      writer.out.write (json.encode value)
    else if request.method == "POST":
      value := json.decode-stream request.body
      if scheme == "ram":
        storage_.ram-store key value
      else:
        storage_.flash-store key value
      writer.out.write (json.encode "ok")

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

  backdoor := Backdoor --storage=storage --device=device
  backdoor.start
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

