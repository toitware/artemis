// Copyright (C) 2023 Toitware ApS.

import expect show *
import .utils

main args:
  with_test_cli --args=args: | test_cli/TestCli |
    run_test test_cli

run_test test_cli/TestCli:
  output := test_cli.run [ "version" ]
  output2 := test_cli.run [ "--version" ]
  expect_equals output output2
  expect_not_equals "" output

  expect (output.starts_with "v")
