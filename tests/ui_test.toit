// Copyright (C) 2023 Toitware ApS. All rights reserved.

import artemis.cli.ui show *
import encoding.json
import expect show *

class TestPrinter extends PrinterBase:
  test_ui_/TestUi
  needs_structured_/bool

  constructor .test_ui_ prefix/string? --needs_structured/bool:
    needs_structured_ = needs_structured
    super prefix

  print_ str/string:
    test_ui_.stdout += "$str\n"

  handle_structured_ o:
    test_ui_.structured.add o

class TestUi extends ConsoleUi:
  stdout := ""
  structured := []

  needs_structured/bool

  constructor --level/int=Ui.NORMAL_LEVEL --.needs_structured/bool:
    super --level=level

  create_printer_ prefix/string? _ -> TestPrinter:
    return TestPrinter this prefix --needs_structured=needs_structured

  reset:
    stdout = ""
    structured = []

class TestJsonPrinter extends JsonPrinter:
  test_ui_/TestJsonUi

  constructor .test_ui_ prefix/string? kind/int:
    super prefix kind

  print_ str/string:
    test_ui_.stderr += "$str\n"

  handle_structured_ structured:
    test_ui_.stdout += (json.stringify structured)

class TestJsonUi extends JsonUi:
  stdout := ""
  stderr := ""

  constructor --level/int=Ui.NORMAL_LEVEL:
    super --level=level

  create_printer_ prefix/string? kind/int -> TestJsonPrinter:
    return TestJsonPrinter this prefix kind

  reset:
    stdout = ""
    stderr = ""

main:
  test_console
  test_structured
  test_json

test_console:
  ui := TestUi --no-needs_structured

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

  ui.do: | printer/Printer |
    printer.emit
        --header={"left": "with", "right": "ints"}
        [
          {
            "left": 1,
            "right": 2,
          },
          {
            "left": 3,
            "right": 4,
          },
        ]
  expect_equals """
  ┌──────┬──────┐
  │ with   ints │
  ├──────┼──────┤
  │ 1      2    │
  │ 3      4    │
  └──────┴──────┘
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

  ui.print {
    "entry with int": 499,
  }
  expect_equals """
  entry with int: 499
  """ ui.stdout
  ui.reset

test_structured:
  ui := TestUi --needs_structured

  ui.info "hello"
  expect_equals ["hello"] ui.structured
  ui.reset

  map := {
    "foo": 1,
    "bar": 2,
  }
  ui.info map
  expect_equals 1 ui.structured.size
  expect_identical map ui.structured[0]
  ui.reset

  list := [
    "foo",
    "bar",
  ]
  ui.info list
  expect_equals 1 ui.structured.size
  expect_identical list ui.structured[0]
  ui.reset

  ui.do: | printer/Printer |
    printer.emit --title="French" ["bonjour", "monde"]
  expect_equals 1 ui.structured.size
  expect_equals ["bonjour", "monde"] ui.structured[0]
  ui.reset

  data := [
    { "x": "a", "y": "b" },
    { "x": "c", "y": "d" },
  ]
  ui.do: | printer/Printer |
    printer.emit
        --header={"x": "x", "y": "y"}
        data
  expect_equals 1 ui.structured.size
  expect_structural_equals data ui.structured[0]
  ui.reset

test_json:
  ui := TestJsonUi

  // Anything that isn't a result is emitted on stderr as if it was
  // a console Ui.
  ui.info "hello"
  expect_equals "hello\n" ui.stderr
  ui.reset

  // Results are emitted on stdout as JSON.
  ui.result "hello"
  expect_equals "\"hello\"" ui.stdout
  ui.reset

  ui.result {
    "foo": 1,
    "bar": 2,
  }
  expect_equals "{\"foo\":1,\"bar\":2}" ui.stdout

  ui.warning "some warning"
  expect_equals "Warning: some warning\n" ui.stderr
  ui.reset

  ui.error "some error"
  expect_equals "Error: some error\n" ui.stderr
  ui.reset
