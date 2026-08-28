// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import .utils
import artemis.service.synchronize show SynchronizeJob
import expect show expect

main args:
  with-tester --args=args: | tester/Tester |
    tester.login

    device := tester.create-device
    device.start

    // Transient commands only work if we know the firmware the device
    // is actually running.
    device.wait-until-connected

    tester.run [
        "fleet", "init",
        "--fleet-root", tester.tmp-dir,
        "--organization-id", "$device.organization-id",
    ]
    tester.run ["fleet", "add-existing-device", "--fleet-root", tester.tmp-dir, "$device.device-id"]

    failure := tester.run --expect-exit-1 [
      "--fleet-root", tester.tmp-dir,
      "device",
      "set-max-offline",
      "--device", "$device.device-id",
      "0s",
    ]
    expect: failure.contains "Max-offline must be greater than zero."

    tester.run [
      "--fleet-root", tester.tmp-dir,
      "device",
      "set-max-offline",
      "--device", "$device.device-id",
      "1",
    ]

    // The device has disconnected using the default max-offline. Restart it
    // so it picks up the shorter interval without waiting five minutes.
    device.stop
    device.start

    // We give the infrastructure some time to react.
    slack := Duration --s=10

    pos := 0
    with-timeout slack:
      pos = device.wait-for "synchronized {max-offline: 1s}" --start-at=pos

    tester.run [
      "--fleet-root", tester.tmp-dir,
      "device",
      "set-max-offline",
      "--device", "$device.device-id",
      "3m",
    ]

    // We've set the max-offline to 1s, but the synchronize job
    // refuses to run that often.
    offline := max (Duration --s=1) SynchronizeJob.OFFLINE-MINIMUM
    with-timeout slack + offline:
      pos = device.wait-for "synchronized {max-offline: 3m0s}" --start-at=pos
