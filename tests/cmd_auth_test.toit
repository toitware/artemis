// Copyright (C) 2023 Toitware ApS.

// TEST_FLAGS: --supabase-server --http-server

import expect show *
import .utils

main args:
  if args.is_empty: args = ["--http-server"]

  artemis_type/string := ?
  if args[0] == "--supabase-server":  artemis_type = "supabase"
  else if args[0] == "--http-server": artemis_type = "http"
  else: throw "Unknown artemis type: $args[0]"

  with_test_cli
      --artemis_type=artemis_type
      --no-start_device_artemis
      : | test_cli/TestCli _ |
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
