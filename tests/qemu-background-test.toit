// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import expect show *
import host.file
import host.directory
import http
import monitor
import net

import .qemu
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
      writer.write "synchro done"
  return port

make-lock-file tests-dir/string -> string:
  // Hackish way to make the package file work with the pod file.
  // The build system already adds the .packages of the tests dir to the
  // environment variable TOIT_PACKAGE_CACHE_PATHS.
  lock-content := (file.read-content "package.lock").to-string
  lock-content = lock-content.replace --all "path: " "path: $tests-dir/"
  return lock-content

make-test-code port/int -> string:
  test-content := TEST-CODE.replace "HOST" get-lan-ip
  return test-content.replace "PORT" "$port"

main args/List:
  with-fleet --args=args --count=0: | test-cli/TestCli _ fleet-dir/string |
    synchro-done-latch := monitor.Latch
    port := start-http-server synchro-done-latch
    test-file := "test.toit"
    test-content := make-test-code port
    lock-file := "package.lock"
    lock-content := make-lock-file directory.cwd

    qemu-data := build-qemu-image
        --test-cli=test-cli
        --args=args
        --fleet-dir=fleet-dir
        --files={
          test-file: test-content,
          lock-file: lock-content
        }
        --pod-spec={
          "max-offline": "2m",
          "containers": {
            "test": {
              "entrypoint": test-file,
            },
          },
        }
    run-test test-cli synchro-done-latch qemu-data

run-test test-cli/TestCli synchro-done-latch/monitor.Latch qemu-data/Map:
  tmp-dir := test-cli.tmp-dir
  ui := TestUi --no-quiet

  image-path := qemu-data["image-path"]
  device-id := qemu-data["device-id"]

  lan-ip := get-lan-ip

  test-device := test-cli.start-device
      --alias-id=device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=device-id
      --qemu-image=image-path

  print "Starting to look for 'INFO: synchronized'."
  test-device.wait-for "INFO: synchronized"
  synchro-done-latch.set "synchronized"
  test-device.wait-for "entering deep sleep for"
  print "Found."
