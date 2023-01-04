// Copyright (C) 2023 Toitware ApS. All rights reserved.

import artemis.cli.ui
import expect show *

class TestUi extends ui.ConsoleUi:
  stdout := ""

  print_ str/string:
    stdout += "$str\n"

  reset:
    stdout = ""

main:
  ui := TestUi

  ui.info "hello"
  expect_equals "hello\n" ui.stdout
  ui.reset

  ui.info_list ["hello", "world"]
  expect_equals "hello\nworld\n" ui.stdout
  ui.reset

  ui.info_list --title="French" ["bonjour", "monde"]
  expect_equals "French:\n  bonjour\n  monde\n" ui.stdout
  ui.reset

  ui.info_table --header=["x", "y"] [
    ["a", "b"],
    ["c", "d"],
  ]
  expect_equals """
  ┌───┬───┐
  │ x   y │
  ├───┼───┤
  │ a   b │
  │ c   d │
  └───┴───┘
  """ ui.stdout
  ui.reset

  ui.info_table --header=["long", "even longer"] [
    ["a", "short"],
    ["longer", "d"],
  ]
  expect_equals """
  ┌────────┬─────────────┐
  │ long     even longer │
  ├────────┼─────────────┤
  │ a        short       │
  │ longer   d           │
  └────────┴─────────────┘
  """ ui.stdout
  ui.reset

  ui.info_table --header=["no", "rows"] []
  expect_equals """
  ┌────┬──────┐
  │ no   rows │
  ├────┼──────┤
  └────┴──────┘
  """ ui.stdout
  ui.reset

  ui.info_table [["no", "header"]]
  expect_equals """
  ┌────┬────────┐
  │ no   header │
  └────┴────────┘
  """ ui.stdout
  ui.reset

  ui.info_table []
  expect_equals "" ui.stdout
  ui.reset

  ui.info_map {
    "a": "b",
    "c": "d",
  }
  expect_equals """
  a: b
  c: d
  """ ui.stdout
  ui.reset

  // Nested maps.
  ui.info_map {
    "a": {
      "b": "c",
      "d": "e",
    },
    "f": "g",
  }
  expect_equals """
  a:
    b: c
    d: e
  f: g
  """ ui.stdout
  ui.reset
