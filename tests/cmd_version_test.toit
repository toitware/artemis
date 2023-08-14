// Copyright (C) 2023 Toitware ApS.

import expect show *
import .utils

main args:
  with-test-cli --args=args: | test-cli/TestCli |
    run-test test-cli

run-test test-cli/TestCli:
  output := test-cli.run [ "version" ]
  output2 := test-cli.run [ "--version" ]
  expect-equals output output2
  expect-not-equals "" output

  expect (output.starts-with "v")
