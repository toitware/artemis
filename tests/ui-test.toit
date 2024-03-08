// Copyright (C) 2023 Toitware ApS. All rights reserved.

import artemis.cli.ui show *
import encoding.json
import expect show *

class TestPrinter extends PrinterBase:
  test-ui_/TestUi
  needs-structured_/bool

  constructor .test-ui_ prefix/string? --needs-structured/bool:
    needs-structured_ = needs-structured
    super prefix

  print_ str/string:
    test-ui_.stdout += "$str\n"

  handle-structured_ o:
    test-ui_.structured.add o

class TestUi extends ConsoleUi:
  stdout := ""
  structured := []

  needs-structured/bool

  constructor --level/int=Ui.NORMAL-LEVEL --.needs-structured/bool:
    super --level=level

  create-printer_ prefix/string? _ -> TestPrinter:
    return TestPrinter this prefix --needs-structured=needs-structured

  reset:
    stdout = ""
    structured = []

  wants-structured-result -> bool:
    return needs-structured

class TestJsonPrinter extends JsonPrinter:
  test-ui_/TestJsonUi

  constructor .test-ui_ prefix/string? kind/int:
    super prefix kind

  print_ str/string:
    test-ui_.stderr += "$str\n"

  handle-structured_ structured:
    test-ui_.stdout += (json.stringify structured)

class TestJsonUi extends JsonUi:
  stdout := ""
  stderr := ""

  constructor --level/int=Ui.NORMAL-LEVEL:
    super --level=level

  create-printer_ prefix/string? kind/int -> TestJsonPrinter:
    return TestJsonPrinter this prefix kind

  reset:
    stdout = ""
    stderr = ""

main:
  test-console
  test-structured
  test-json

test-console:
  ui := TestUi --no-needs-structured

  ui.info "hello"
  expect-equals "hello\n" ui.stdout
  ui.reset

  ui.info ["hello", "world"]
  expect-equals "hello\nworld\n" ui.stdout
  ui.reset

  ui.do: | printer/Printer |
    printer.emit --title="French" ["bonjour", "monde"]
  expect-equals "French:\n  bonjour\n  monde\n" ui.stdout
  ui.reset

  ui.do: | printer/Printer |
    printer.emit
        --header={"x": "x", "y": "y"}
        [
          { "x": "a", "y": "b" },
          { "x": "c", "y": "d" },
        ]
  expect-equals """
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
  expect-equals """
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
  expect-equals """
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
  expect-equals """
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
  expect-equals """
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
  expect-equals """
  a:
    b: c
    d: e
  f: g
  """ ui.stdout
  ui.reset

  ui.print "foo"
  expect-equals "foo\n" ui.stdout
  ui.reset

  ui.warning "foo"
  expect-equals "Warning: foo\n" ui.stdout
  ui.reset

  ui.error "foo"
  expect-equals "Error: foo\n" ui.stdout
  ui.reset

  ui.print {
    "entry with int": 499,
  }
  expect-equals """
  entry with int: 499
  """ ui.stdout
  ui.reset

test-structured:
  ui := TestUi --needs-structured

  ui.info "hello"
  expect-equals ["hello"] ui.structured
  ui.reset

  map := {
    "foo": 1,
    "bar": 2,
  }
  ui.info map
  expect-equals 1 ui.structured.size
  expect-identical map ui.structured[0]
  ui.reset

  list := [
    "foo",
    "bar",
  ]
  ui.info list
  expect-equals 1 ui.structured.size
  expect-identical list ui.structured[0]
  ui.reset

  ui.do: | printer/Printer |
    printer.emit --title="French" ["bonjour", "monde"]
  expect-equals 1 ui.structured.size
  expect-equals ["bonjour", "monde"] ui.structured[0]
  ui.reset

  data := [
    { "x": "a", "y": "b" },
    { "x": "c", "y": "d" },
  ]
  ui.do: | printer/Printer |
    printer.emit
        --header={"x": "x", "y": "y"}
        data
  expect-equals 1 ui.structured.size
  expect-structural-equals data ui.structured[0]
  ui.reset

test-json:
  ui := TestJsonUi

  // Anything that isn't a result is emitted on stderr as if it was
  // a console Ui.
  ui.info "hello"
  expect-equals "hello\n" ui.stderr
  ui.reset

  // Results are emitted on stdout as JSON.
  ui.result "hello"
  expect-equals "\"hello\"" ui.stdout
  ui.reset

  ui.result {
    "foo": 1,
    "bar": 2,
  }
  expect-equals "{\"foo\":1,\"bar\":2}" ui.stdout

  ui.warning "some warning"
  expect-equals "Warning: some warning\n" ui.stderr
  ui.reset

  ui.error "some error"
  expect-equals "Error: some error\n" ui.stderr
  ui.reset
