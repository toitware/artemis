// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import .utils
import artemis.service.synchronize show SynchronizeJob

main args:
  with-test-cli --args=args: | test-cli/TestCli |
    test-cli.run [
      "auth", "login",
      "--email", TEST-EXAMPLE-COM-EMAIL,
      "--password", TEST-EXAMPLE-COM-PASSWORD,
    ]

    test-cli.run [
      "auth", "login",
      "--broker",
      "--email", TEST-EXAMPLE-COM-EMAIL,
      "--password", TEST-EXAMPLE-COM-PASSWORD,
    ]

    device := test-cli.create-device
    device.start

    // Transient commands only work if we know the firmware the device
    // is actually running.
    device.wait-until-connected

    test-cli.run [
        "fleet", "init",
        "--fleet-root", test-cli.tmp-dir,
        "--organization-id", "$device.organization-id",
    ]
    test-cli.run ["fleet", "add-existing-device", "--fleet-root", test-cli.tmp-dir, "$device.alias-id"]

    test-cli.run [
      "--fleet-root", test-cli.tmp-dir,
      "device",
      "set-max-offline",
      "--device", "$device.alias-id",
      "1",
    ]

    // We give the infrastructure some time to react.
    slack := Duration --s=10

    pos := 0
    with-timeout slack:
      pos = device.wait-for "synchronized {max-offline: 1s}" --start-at=pos

    test-cli.run [
      "--fleet-root", test-cli.tmp-dir,
      "device",
      "set-max-offline",
      "--device", "$device.alias-id",
      "3m",
    ]

    // We've set the max-offline to 1s, but the synchronize job
    // refuses to run that often.
    offline := max (Duration --s=1) SynchronizeJob.OFFLINE-MINIMUM
    with-timeout slack + offline:
      pos = device.wait-for "synchronized {max-offline: 3m0s}" --start-at=pos
