// Copyright (C) 2023 Toitware ApS. All rights reserved.

// TODO(florian): move this library to the cli package.

import supabase
import cli
import encoding.json

interface Printer:
  emit o/any --title/string?=null --header/Map?=null
  emit-structured [--json] [--stdout]

abstract class PrinterBase implements Printer:
  prefix_/string? := ?
  constructor .prefix_:

  abstract needs-structured_ -> bool
  abstract print_ str/string
  abstract handle-structured_ o/any

  emit o/any --title/string?=null --header/Map?=null:
    if needs-structured_:
      handle-structured_ o
      return

    if o is string:
      message := o as string
      if title:
        message = "$title: $message"
      if prefix_:
        message = "$prefix_$message"
        prefix_ = null
      print_ message
      return

    if prefix_:
      print_ prefix_
      prefix_ = null

    if o is List and header:
      emit-table_ --title=title --header=header (o as List)
      return

    indentation := ""
    if title:
      print_ "$title:"
      indentation = "  "

    if o is List:
      emit-list_ (o as List) --indentation=indentation
    else if o is Map:
      emit-map_ (o as Map) --indentation=indentation
    else:
      throw "Invalid type"

  emit-list_ list/List --indentation/string:
    list.do:
      // TODO(florian): should the entries be recursively pretty-printed?
      print_ "$indentation$it"

  emit-map_ map/Map --indentation/string:
    map.do: | key value |
      if value is Map:
        print_ "$indentation$key:"
        emit-map_ value --indentation="$indentation  "
      else:
        // TODO(florian): should the entries handle lists as well.
        print_ "$indentation$key: $value"

  emit-table_ --title/string?=null --header/Map table/List:
    if needs-structured_:
      handle-structured_ table
      return

    if prefix_:
      print_ prefix_
      prefix_ = null

    // TODO(florian): make this look nicer.
    if title:
      print_ "$title:"

    column-count := header.size
    column-sizes := header.map: | _ header-string/string | header-string.size --runes

    table.do: | row/Map |
      header.do --keys: | key/string |
        entry/string := "$row[key]"
        column-sizes.update key: | old/int | max old (entry.size --runes)

    pad := : | o/Map |
      padded-row := []
      column-sizes.do: | key size |
        entry := "$o[key]"
        // TODO(florian): allow alignment.
        padded := entry + " " * (size - (entry.size --runes))
        padded-row.add padded
      padded-row

    bars := column-sizes.values.map: "─" * it
    print_ "┌─$(bars.join "─┬─")─┐"

    sized-header-entries := []
    padded-row := pad.call header
    print_ "│ $(padded-row.join "   ") │"
    print_ "├─$(bars.join "─┼─")─┤"

    table.do: | row |
      padded-row = pad.call row
      print_ "│ $(padded-row.join "   ") │"
    print_ "└─$(bars.join "─┴─")─┘"

  emit-structured [--json] [--stdout]:
    if needs-structured_:
      handle-structured_ json.call
      return

    stdout.call this

/**
A class for handling input/output from the user.

The Ui class is used to display text to the user and to get input from the user.
*/
abstract class Ui implements supabase.Ui cli.Ui:
  static DEBUG ::= 0
  static VERBOSE ::= 1
  static INFO ::= 2
  static WARNING ::= 3
  static INTERACTIVE ::= 4
  static ERROR ::= 5
  static RESULT ::= 6

  static DEBUG-LEVEL ::= -1
  static VERBOSE-LEVEL ::= -2
  static NORMAL-LEVEL ::= -3
  static QUIET-LEVEL ::= -4
  static SILENT-LEVEL ::= -5

  level/int
  constructor --.level/int:
    if not DEBUG-LEVEL >= level >= SILENT-LEVEL:
      error "Invalid level: $level"

  do --kind/int=Ui.INFO [generator] -> none:
    if level == DEBUG-LEVEL:
      // Always triggers.
    else if level == VERBOSE-LEVEL:
      if kind < VERBOSE: return
    else if level == NORMAL-LEVEL:
      if kind < INFO: return
    else if level == QUIET-LEVEL:
      if kind < INTERACTIVE: return
    else if level == SILENT-LEVEL:
      if kind < RESULT: return
    else:
      error "Invalid level: $level"
    generator.call (printer_ --kind=kind)

  /** Reports an error. */
  error o/any:
    do --kind=ERROR: | printer/Printer | printer.emit o

  /** Reports a warning. */
  warning o/any:
    do --kind=WARNING: | printer/Printer | printer.emit o

  info o/any:
    do --kind=INFO: | printer/Printer | printer.emit o

  print o/any: info o

  result o/any:
    do --kind=RESULT: | printer/Printer | printer.emit o

  abort o/any:
    do --kind=ERROR: | printer/Printer | printer.emit o
    abort

  printer_ --kind/int -> Printer:
    prefix/string? := null
    if kind == Ui.WARNING:
      prefix = "Warning: "
    else if kind == Ui.ERROR:
      prefix = "Error: "
    return create-printer_ prefix kind

  /**
  Aborts the program with the given error message.

  # Inheritance
  It is safe to override this method with a custom implementation. The
    method should always abort. Either with 'exit 1', or with an exception.
  */
  abort -> none:
    exit 1

  /**
  Creates a new printer for the given $kind.

  # Inheritance
  Customization generally happens at this level, by providing different
    implementations of the $Printer class.
  */
  abstract create-printer_ prefix/string? kind/int -> Printer

/**
Prints the given $str using $print.

This function is necessary, as $ConsolePrinter has its own 'print' method,
  which shadows the global one.
*/
global-print_ str/string:
  print str

class ConsolePrinter extends PrinterBase:
  constructor prefix/string?:
    super prefix

  needs-structured_: return false

  print_ str/string:
    global-print_ str

  handle-structured_ structured:
    unreachable

class ConsoleUi extends Ui:

  constructor --level/int=Ui.NORMAL-LEVEL:
    super --level=level

  create-printer_ prefix/string? kind/int -> Printer:
    return ConsolePrinter prefix

class JsonPrinter extends PrinterBase:
  kind_/int

  constructor prefix/string? .kind_:
    super prefix

  needs-structured_: return kind_ == Ui.RESULT

  print_ str/string:
    print-on-stderr_ str

  handle-structured_ structured:
    global-print_ (json.stringify structured)

class JsonUi extends Ui:
  constructor --level/int=Ui.QUIET-LEVEL:
    super --level=level

  create-printer_ prefix/string? kind/int -> Printer:
    return JsonPrinter prefix kind
