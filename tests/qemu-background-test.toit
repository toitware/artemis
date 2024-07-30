// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import expect show *
import host.file
import host.directory
import http
import monitor
import net

import .cli-device-extract
import .utils
import ..tools.lan-ip.lan-ip

TEST-CODE ::= """
import http
import net
import system.containers

main:
  print "Requesting data from test-driver."
  network := net.open
  client := http.Client network
  client.get --uri="http://HOST:PORT/foo"
  client.close
  network.close
  print "Not yet background."
  sleep --ms=100
  print "Switching to background."
  containers.notify-background-state-changed true
  // Despite the loop we will enter deep sleep.
  while true:
    sleep --ms=5_000
"""

start-http-server synchro-done-latch/monitor.Latch -> int:
  network := net.open
  socket := network.tcp-listen 0
  port := socket.local-address.port
  server := http.Server --max-tasks=64
  print "Listening on port $socket.local-address.port"
  task --background::
    server.listen socket:: | request/http.Request writer/http.ResponseWriter |
      print "Got request from device."
      synchro-done-latch.get
      writer.out.write "synchro done"
  return port

make-test-code port/int -> string:
  test-content := TEST-CODE.replace "HOST" get-lan-ip
  return test-content.replace "PORT" "$port"

main args/List:
  with-fleet --args=args --count=0: | fleet/TestFleet |
    synchro-done-latch := monitor.Latch
    port := start-http-server synchro-done-latch
    test-file := "test.toit"
    test-content := make-test-code port


    qemu-data := create-extract-device
        --fleet=fleet
        --format="qemu"
        --files={
          test-file: test-content,
        }
        --pod-spec={
          "max-offline": "2m",
          "containers": {
            "test": {
              "entrypoint": test-file,
            },
          },
        }
    run-test fleet.tester synchro-done-latch qemu-data

run-test tester/Tester synchro-done-latch/monitor.Latch qemu-data/TestDeviceConfig:
  tmp-dir := tester.tmp-dir
  ui := TestUi --no-quiet

  device-id := qemu-data.device-id

  lan-ip := get-lan-ip

  test-device := tester.create-device
      --alias-id=device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=device-id
      --device-config=qemu-data
  test-device.start

  print "Starting to look for 'INFO: synchronized'."
  pos := test-device.wait-for-synchronized --start-at=0
  synchro-done-latch.set "synchronized"
  test-device.wait-for "entering deep sleep for" --start-at=pos
  print "Found."
  test-device.close
