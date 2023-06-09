// Copyright (C) 2023 Toitware ApS.

import expect show *
import fs

BASE_DIR_TESTS ::= [
  ["foo", "."],
  ["foo/bar", "foo"],
  ["foo/bar/baz", "foo/bar"],
]

main:
  BASE_DIR_TESTS.do: | test/List |
    input := test[0]
    expected := test[1]
    actual := fs.dirname input
    expect_equals expected actual
