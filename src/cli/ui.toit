// Copyright (C) 2023 Toitware ApS. All rights reserved.

// TODO(florian): move this library to the cli package.

import supabase
import cli

interface Printer:
  emit o/any --title/string?=null --header/Map?=null
  emit_structured [--json] [--stdout]

abstract class PrinterBase implements Printer:
  prefix_/string? := ?
  constructor .prefix_:

  abstract needs_structured_ -> bool
  abstract print_ str/string
  abstract handle_structured_ o/any

  emit o/any --title/string?=null --header/Map?=null:
    if needs_structured_:
      handle_structured_ o
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
      emit_table_ --title=title --header=header (o as List)
      return

    indentation := ""
    if title:
      print_ "$title:"
      indentation = "  "

    if o is List:
      emit_list_ (o as List) --indentation=indentation
    else if o is Map:
      emit_map_ (o as Map) --indentation=indentation
    else:
      throw "Invalid type"

  emit_list_ list/List --indentation/string:
    list.do:
      // TODO(florian): should the entries be recursively pretty-printed?
      print_ "$indentation$it"

  emit_map_ map/Map --indentation/string:
    map.do: | key value |
      if value is Map:
        print_ "$indentation$key:"
        emit_map_ value --indentation="$indentation  "
      else:
        // TODO(florian): should the entries handle lists as well.
        print_ "$indentation$key: $value"

  emit_table_ --title/string?=null --header/Map table/List:
    if needs_structured_:
      handle_structured_ table
      return

    if prefix_:
      print_ prefix_
      prefix_ = null

    // TODO(florian): make this look nicer.
    if title:
      print_ "$title:"

    column_count := header.size
    column_sizes := header.map: | _ header_string/string | header_string.size --runes

    table.do: | row/Map |
      header.do --keys: | key/string |
        entry/string := "$row[key]"
        column_sizes.update key: | old/int | max old (entry.size --runes)

    pad := : | o/Map |
      padded_row := []
      column_sizes.do: | key size |
        entry := "$o[key]"
        // TODO(florian): allow alignment.
        padded := entry + " " * (size - (entry.size --runes))
        padded_row.add padded
      padded_row

    bars := column_sizes.values.map: "─" * it
    print_ "┌─$(bars.join "─┬─")─┐"

    sized_header_entries := []
    padded_row := pad.call header
    print_ "│ $(padded_row.join "   ") │"
    print_ "├─$(bars.join "─┼─")─┤"

    table.do: | row |
      padded_row = pad.call row
      print_ "│ $(padded_row.join "   ") │"
    print_ "└─$(bars.join "─┴─")─┘"

  emit_structured [--json] [--stdout]:
    if needs_structured_:
      handle_structured_ json.call
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

  static DEBUG_LEVEL ::= -1
  static VERBOSE_LEVEL ::= -2
  static NORMAL_LEVEL ::= -3
  static QUIET_LEVEL ::= -4
  static SILENT_LEVEL ::= -5

  level/int
  constructor --.level/int:
    if not DEBUG_LEVEL >= level >= SILENT_LEVEL:
      error "Invalid level: $level"

  abstract printer_ --kind/int -> Printer
  abstract abort -> none

  do --kind/int=Ui.INFO [generator] -> none:
    if level == DEBUG_LEVEL:
      // Always triggers.
    else if level == VERBOSE_LEVEL:
      if kind < VERBOSE: return
    else if level == NORMAL_LEVEL:
      if kind < INFO: return
    else if level == QUIET_LEVEL:
      if kind < INTERACTIVE: return
    else if level == SILENT_LEVEL:
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

/**
Prints the given $str using $print.

This function is necessary, as $ConsolePrinter has its own 'print' method,
  which shadows the global one.
*/
global_print_ str/string:
  print str

class ConsolePrinter extends PrinterBase:
  constructor prefix/string?:
    super prefix

  needs_structured_: return false

  print_ str/string:
    global_print_ str

  handle_structured_ structured:
    unreachable

class ConsoleUi extends Ui:

  constructor --level/int=Ui.NORMAL_LEVEL:
    super --level=level

  printer_ --kind/int -> Printer:
    prefix/string? := null
    if kind == Ui.WARNING:
      prefix = "Warning: "
    else if kind == Ui.ERROR:
      prefix = "Error: "
    return create_printer_ prefix

  create_printer_ prefix/string? -> Printer:
    return ConsolePrinter prefix

  abort -> none:
    exit 1
