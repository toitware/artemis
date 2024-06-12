// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import encoding.json
import host.file
import expect show *
import .utils

main args:
  with-test-cli --args=args: | test-cli/TestCli |
    run-test test-cli

run-test test-cli/TestCli:
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

  with-tmp-directory: | fleet-tmp-dir |
    test-cli.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]

    expect (file.is-file "$fleet-tmp-dir/fleet.json")
    expect (file.is-file "$fleet-tmp-dir/devices.json")
    expect (file.is-file "$fleet-tmp-dir/my-pod.yaml")

    fleet-json := json.decode (file.read-content "$fleet-tmp-dir/fleet.json")
    // Check that we have a broker entry.
    broker-entry := fleet-json["servers"]["broker"]

    // We are not allowed to initialize a folder twice.
    already-initialized-message := test-cli.run --expect-exit-1 [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]
    expect (already-initialized-message.contains "already contains a fleet.json file")

  with-tmp-directory: | fleet-tmp-dir |
    bad-org-id-message := test-cli.run --expect-exit-1 [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$NON-EXISTENT-UUID",
    ]
    expect (bad-org-id-message.contains "does not exist or")

  with-tmp-directory: | fleet-tmp-dir |
    // Get the current default broker.
    default-broker := test-cli.run --json ["config", "broker", "default"]
    test-cli.run [
      // Add a non-existing broker, and make it the default.
      "config", "broker", "add", "http", "--port", "1235", "testy",
    ]
    expect-equals "testy" (test-cli.run --json ["config", "broker", "default"])

    // Initialize a new fleet with the old broker.
    test-cli.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
      "--broker", default-broker,
    ]

    // Test that we can talk to the broker.
    test-cli.run [
      "pod", "list",
      "--fleet-root", fleet-tmp-dir,
    ]
