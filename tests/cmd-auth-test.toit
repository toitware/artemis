// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import expect show *
import .utils

main args:
  with-test-cli --args=args: | test-cli/TestCli |
    run-test test-cli

run-test test-cli/TestCli:
  test-start := Time.now

  // Some command that requires to be authenticated.
  output := test-cli.run --expect-exit-1 ["org", "list"]
  expect (output.contains "Not logged in")

  test-cli.run [
    "auth", "login",
    "--email", TEST-EXAMPLE-COM-EMAIL,
    "--password", TEST-EXAMPLE-COM-PASSWORD,
  ]

  output = test-cli.run ["org", "list"]
  expect-not (output.contains "Not logged in")

  test-cli.run ["auth", "logout"]

  output = test-cli.run --expect-exit-1 ["org", "list"]
  expect (output.contains "Not logged in")
