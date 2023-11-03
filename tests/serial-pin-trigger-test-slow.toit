// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import uuid
import host.os

import .serial
import .utils

/**
Tests the pin trigger.

Requires pin 32 and pin33 to be connected.
Since we are running on a single device we can't test wake up from
  deep sleep this way.
*/

TEST-CODE ::= """
import gpio
import artemis-pkg.artemis

main:
  print "hello"
  reason := artemis.Container.current.trigger
  print "reason: \$reason"

  pin := gpio.Pin --input 32
  print "Can access pin 32: \$pin.get"


  if reason is artemis.TriggerPin:
    artemis.Container.current.set-next-start-triggers [
      artemis.TriggerInterval Duration.ZERO,
    ]
  else:
    artemis.Container.current.set-next-start-triggers [
      artemis.TriggerPin 32 --level=1,
      // The interval trigger must not delay the execution of the pin trigger.
      artemis.TriggerInterval (Duration --h=1),
    ]
  print "done without closing"
"""

TRIGGER-PIN-32-CODE ::= """
import gpio

main:
  // This pin is connected to pin 32 on the device.
  pin := gpio.Pin --output 33
  print "sleeping 2s before triggering pin"
  sleep (Duration --s=2)
  print "triggering pin"
  pin.set 1
  // Keep the pin high.
  sleep (Duration --s=10)
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

  with-fleet --args=args --count=0: | test-cli/TestCli _ fleet-dir/string |
    run-test test-cli fleet-dir serial-port wifi-ssid wifi-password

run-test test-cli/TestCli fleet-dir/string serial-port/string wifi-ssid/string wifi-password/string:
  device-id := flash-serial
      --wifi-ssid=wifi-ssid
      --wifi-password=wifi-password
      --port=serial-port
      --test-cli=test-cli
      --fleet-dir=fleet-dir
      --files={
        "test.toit": TEST-CODE,
        "trigger-pin-32.toit": TRIGGER-PIN-32-CODE,
      }

  test-device := test-cli.listen-to-serial-device
      --serial-port=serial-port
      --alias-id=device-id
      // We don't know the actual hardware-id.
      // Cheat by reusing the alias id.
      --hardware-id=device-id

  pos := test-device.wait-for "done without closing" --start-at=0
  pos = test-device.wait-for "reason: Trigger - pin 32-1" --start-at=pos
  pos = test-device.wait-for "reason: Trigger - interval" --start-at=pos
  test-device.wait-for "Can access pin 32" --start-at=pos
