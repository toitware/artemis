// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import expect show *
import .utils

main args:
  with_test_cli --args=args: | test_cli/TestCli _ |
    run_test test_cli

run_test test_cli/TestCli:
  test_start := Time.now

  // Some command that requires to be authenticated.
  output := test_cli.run --expect_exit_1 [ "org", "list" ]
  expect (output.contains "Not logged in")

  test_cli.run [
    "auth", "artemis", "login",
    "--email", TEST_EXAMPLE_COM_EMAIL,
    "--password", TEST_EXAMPLE_COM_PASSWORD,
  ]

  output = test_cli.run [ "org", "list" ]
  expect_not (output.contains "Not logged in")
