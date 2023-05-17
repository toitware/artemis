// Copyright (C) 2023 Toitware ApS. All rights reserved.

import artemis.cli.ui show *
import expect show *

class TestPrinter extends ConsolePrinter:
  test_ui_/TestUi
  constructor .test_ui_ prefix/string?:
    super prefix

  print_ str/string:
    test_ui_.stdout += "$str\n"

class TestUi extends ConsoleUi:
  stdout := ""

  constructor --level/int=Ui.NORMAL_LEVEL:
    super --level=level

  create_printer_ prefix/string? -> TestPrinter:
    return TestPrinter this prefix

  reset:
    stdout = ""

main:
  ui := TestUi

  ui.info "hello"
  expect_equals "hello\n" ui.stdout
  ui.reset

  ui.info ["hello", "world"]
  expect_equals "hello\nworld\n" ui.stdout
  ui.reset

  ui.do: | printer/Printer |
    printer.emit --title="French" ["bonjour", "monde"]
  expect_equals "French:\n  bonjour\n  monde\n" ui.stdout
  ui.reset

  ui.do: | printer/Printer |
    printer.emit
        --header={"x": "x", "y": "y"}
        [
          { "x": "a", "y": "b" },
          { "x": "c", "y": "d" },
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

  ui.do: | printer/Printer |
    printer.emit
        --header={ "left": "long", "right": "even longer" }
        [
          { "left": "a", "right": "short" },
          { "left": "longer", "right": "d" },
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

  ui.do: | printer/Printer |
    printer.emit
        --header={"left": "no", "right": "rows"}
        []
  expect_equals """
  ┌────┬──────┐
  │ no   rows │
  ├────┼──────┤
  └────┴──────┘
  """ ui.stdout
  ui.reset

  ui.info {
    "a": "b",
    "c": "d",
  }
  expect_equals """
  a: b
  c: d
  """ ui.stdout
  ui.reset

  // Nested maps.
  ui.info {
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

  ui.print "foo"
  expect_equals "foo\n" ui.stdout
  ui.reset

  ui.warning "foo"
  expect_equals "Warning: foo\n" ui.stdout
  ui.reset

  ui.error "foo"
  expect_equals "Error: foo\n" ui.stdout
  ui.reset
