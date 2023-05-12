// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import .utils
import artemis.service.synchronize show SynchronizeJob

main args:
  with_test_cli --args=args: | test_cli/TestCli |
    test_cli.run [
      "auth", "login",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    test_cli.run [
      "auth", "login",
      "--broker",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    device := test_cli.start_device

    // Transient commands only work if we know the firmware the device
    // is actually running.
    device.wait_until_connected

    test_cli.run [
        "fleet", "init",
        "--fleet-root", test_cli.tmp_dir,
        "--organization-id", "$device.organization_id",
    ]
    test_cli.run ["fleet", "add-device", "--fleet-root", test_cli.tmp_dir, "$device.alias_id"]

    test_cli.run [
      "--fleet-root", test_cli.tmp_dir,
      "device",
      "set-max-offline",
      "--device", "$device.alias_id",
      "1",
    ]

    // We give the infrastructure some time to react.
    slack := Duration --s=10

    with_timeout slack:
      device.wait_for "synchronized {max-offline: 1s}"

    test_cli.run [
      "--fleet-root", test_cli.tmp_dir,
      "device",
      "set-max-offline",
      "--device", "$device.alias_id",
      "3m",
    ]

    // We've set the max-offline to 1s, but the synchronize job
    // refuses to run that often.
    offline := max (Duration --s=1) SynchronizeJob.OFFLINE_MINIMUM
    with_timeout slack + offline:
      device.wait_for "synchronized {max-offline: 3m0s}"
