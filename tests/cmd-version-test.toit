// Copyright (C) 2023 Toitware ApS.

import expect show *
import .utils

main args:
  with-tester --args=args: | tester/Tester |
    run-test tester

run-test tester/Tester:
  output := tester.run [ "version" ]
  output2 := tester.run [ "--version" ]
  expect-equals output output2
  expect-not-equals "" output

  expect (output.starts-with "v")
