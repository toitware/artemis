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

start-backdoor --storage/Storage --device/service.Device:
  network := net.open
  // Listen on a free port.
  tcp-socket := network.tcp-listen 0
  print "$BACKDOOR-PREFIX http://localhost:$tcp-socket.local-address.port"
  print BACKDOOR-FOOTER
  server := http.Server
  task::
    server.listen tcp-socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
      resource := request.query.resource
      if resource == "/device-id":
        writer.out.write (json.encode "$device.id")
      else if resource.starts-with "/storage/":
        segments := resource.split "/"
        if segments.size != 4: throw "invalid resource"
        scheme := segments[2]
        key := segments[3]
        if request.method == "GET":
          writer.headers.add "Content-Type" "application/json"
          value := scheme == "ram" ? storage.ram-load key : storage.flash-load key
          writer.out.write (json.encode value)
        else if request.method == "POST":
          value := json.decode-stream request.body
          if scheme == "ram":
            storage.ram-store key value
          else:
            storage.flash-store key value
          writer.out.write (json.encode "ok")
      else:
        throw "unknown resource"
      writer.close

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

  start-backdoor --storage=storage --device=device
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

