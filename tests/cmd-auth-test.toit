// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import expect show *
import .utils

main args:
  with-tester --args=args: | tester/Tester |
    run-test tester

run-test tester/Tester:
  test-start := Time.now

  // Some command that requires to be authenticated.
  output := tester.run --expect-exit-1 ["org", "list"]
  // Non-admin brokers report "does not support" instead of "Not logged in".
  if output.contains "does not support":
    // The broker doesn't support admin operations, so we can't test
    // org-based auth flow. Just verify login/logout don't crash.
    tester.run [
      "auth", "login",
      "--email", TEST-EXAMPLE-COM-EMAIL,
      "--password", TEST-EXAMPLE-COM-PASSWORD,
    ]
    tester.run ["auth", "logout"]
    return

  expect (output.contains "Not logged in")

  tester.run [
    "auth", "login",
    "--email", TEST-EXAMPLE-COM-EMAIL,
    "--password", TEST-EXAMPLE-COM-PASSWORD,
  ]

  output = tester.run ["org", "list"]
  expect-not (output.contains "Not logged in")

  tester.run ["auth", "logout"]

  output = tester.run --expect-exit-1 ["org", "list"]
  expect (output.contains "Not logged in")
