// Copyright (C) 2023 Toitware ApS.

import expect show *
import .utils

main args:
  with_test_cli --args=args: | test_cli/TestCli _ |
    run_test test_cli

run_test test_cli/TestCli:
  test_start := Time.now

  test_cli.run [
    "auth", "artemis", "login",
    "--email", TEST_EXAMPLE_COM_EMAIL,
    "--password", TEST_EXAMPLE_COM_PASSWORD,
  ]

  bad_id := NON_EXISTENT_UUID
  output := test_cli.run --expect_exit_1 [
    "device", "flash",
    "--organization_id", bad_id,  // We are testing the bad ID here.
    "--specification", "doesn't matter",
    "--port", "doesn't-matter",
  ]

  expect (output.contains "$bad_id does not exist")
