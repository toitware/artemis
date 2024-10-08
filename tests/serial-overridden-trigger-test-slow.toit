// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import expect show *
import net
import uuid show Uuid
import host.os

import .serial
import .synchronizer
import .utils

/**
Tests that overridden triggers survive deep sleeps.
*/

TEST-CODE ::= """
import artemis-pkg.artemis
import net

main:
  print "Hello."
  reason := artemis.Container.current.trigger
  if "\$reason".contains "boot":
    // The host might need a bit of time before it is ready to listen to the
    // UART, so we need to wait before printing things.
    network := net.open
    socket := network.tcp-connect "HOST" PORT
    // Wait for a message from the socket.
    socket.in.read
    socket.close
  print "Reason: \$reason."

  next-trigger := ?
  if reason is not artemis.TriggerInterval:
    next-trigger = artemis.TriggerInterval (Duration --s=1)
  else:
    interval-trigger := reason as artemis.TriggerInterval
    next-trigger = artemis.TriggerInterval (interval-trigger.interval + (Duration --s=1))

  artemis.Container.current.set-next-start-triggers [
    next-trigger
  ]
  print "Next trigger is \$next-trigger."
"""

TEST-PERIODIC-CODE ::= """
import artemis-pkg.artemis

main:
  // Schedule this container to run every second.
  // This way we have a deep-sleep between some of the test-container runs.
  artemis.Container.current.set-next-start-triggers [
    artemis.TriggerInterval (Duration --s=1)
  ]
"""

main args/List:
  serial-port := os.env.get "ARTEMIS_TEST_SERIAL_PORT"
  if not serial-port:
    print "Missing ARTEMIS_TEST_SERIAL_PORT environment variable."
    exit 1
  wifi-ssid := os.env.get "ARTEMIS_TEST_WIFI_SSID"
  if not wifi-ssid:
    print "Missing ARTEMIS_TEST_WIFI_SSID environment variable."
    exit 1
  wifi-password := os.env.get "ARTEMIS_TEST_WIFI_PASSWORD"
  if not wifi-password:
    print "Missing ARTEMIS_TEST_WIFI_PASSWORD environment variable."
    exit 1

  with-fleet --args=args --count=0: | fleet/TestFleet |
    run-test fleet serial-port wifi-ssid wifi-password

run-test fleet/TestFleet serial-port/string wifi-ssid/string wifi-password/string:
  synchronizer := Synchronizer
  test-code := TEST-CODE
  test-code = test-code.replace "HOST" synchronizer.ip
  test-code = test-code.replace "PORT" "$synchronizer.port"

  device-id := flash-serial
      --wifi-ssid=wifi-ssid
      --wifi-password=wifi-password
      --port=serial-port
      --fleet=fleet
      --files={
        "test.toit": test-code,
        "test2.toit": TEST-PERIODIC-CODE,
      }
      --pod-spec={
        "max-offline": "2m"
      }

  test-device := fleet.listen-to-serial-device
      --serial-port=serial-port
      --alias-id=device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=device-id

  synchronizer.signal

  pos := test-device.wait-for "Reason: Trigger - boot" --start-at=0
  expected-interval := 1
  // We need to wait for the synchronization to succeed (or fail) before we can
  // see the first deep sleep.
  while not test-device.output.contains "entering deep sleep":
    pos = test-device.wait-for "Reason: Trigger - interval $(expected-interval)s" --start-at=pos
    expected-interval++
  test-device.wait-for "Reason: Trigger - interval $(expected-interval)s" --start-at=pos

  synchronizer.close
