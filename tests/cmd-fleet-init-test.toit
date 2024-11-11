// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import encoding.json
import host.file
import expect show *
import .utils

main args:
  with-tester --args=args: | tester/Tester |
    run-test tester

run-test tester/Tester:
  tester.login

  with-tmp-directory: | fleet-tmp-dir |
    tester.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]

    expect (file.is-file "$fleet-tmp-dir/fleet.json")
    expect (file.is-file "$fleet-tmp-dir/devices.json")
    expect (file.is-file "$fleet-tmp-dir/my-pod.yaml")

    fleet-json := json.decode (file.read-contents "$fleet-tmp-dir/fleet.json")
    // Check that we have a broker entry.
    broker-name := fleet-json["broker"]
    broker-entry := fleet-json["servers"][broker-name]

    // We are not allowed to initialize a folder twice.
    already-initialized-message := tester.run --expect-exit-1 [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]
    expect (already-initialized-message.contains "already contains a fleet.json file")

  with-tmp-directory: | fleet-tmp-dir |
    bad-org-id-message := tester.run --expect-exit-1 [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$NON-EXISTENT-UUID",
    ]
    expect (bad-org-id-message.contains "does not exist or")

  with-tmp-directory: | fleet-tmp-dir |
    // Get the current default broker.
    default-broker := tester.run --json ["config", "broker", "default"]
    tester.run [
      // Add a non-existing broker, and make it the default.
      "config", "broker", "add", "http", "--port", "1235", "testy",
    ]
    expect-equals "testy" (tester.run --json ["config", "broker", "default"])

    // Initialize a new fleet with the old broker.
    tester.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
      "--broker", default-broker,
    ]

    // Test that we can talk to the broker.
    tester.run [
      "pod", "list",
      "--fleet-root", fleet-tmp-dir,
    ]
