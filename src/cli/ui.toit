// Copyright (C) 2023 Toitware ApS. All rights reserved.

// TODO(florian): move this library to the cli package.

import supabase
import cli

/**
A class for handling input/output from the user.

The Ui class is used to display text to the user and to get input from the user.
*/
interface Ui implements supabase.Ui cli.Ui:
  /** Reports an error. */
  error str/string

  /** Reports information. */
  info str/string

  /** Reports information as a list. */
  info_list list/List --title/string?=null

  /** Reports information as a table. */
  info_table rows/List --header/List?=null

  /** Reports information in a structured way. */
  info_map map/Map

  print str/string

  abort

/**
Prints the given $str using $print.

This function is necessary, as $ConsoleUi has its own 'print' method,
  which shadows the global one.
*/
global_print_ str/string:
  print str

class ConsoleUi implements Ui:
  error str/string:
    print_ "Error: $str"

  print str/string:
    print_ str

  info str/string:
    print_ str

  info_list list/List --title/string?=null:
    indentation := ""
    if title:
      print_ "$title:"
      indentation = "  "

    list.do:
      print_ "$indentation$it"

  info_table rows/List --header/List?=null:
    if rows.is_empty and not header: return
    column_count := rows.is_empty ? header.size : rows[0].size
    column_sizes := List column_count: 0

    if header:
      header.size.repeat:
        column_sizes[it] = header[it].size

    rows.do: | row |
      row.size.repeat:
        column_sizes[it] = max column_sizes[it] row[it].size
    bars := column_sizes.map: "─" * it
    print_ "┌─$(bars.join "─┬─")─┐"
    if header != null:
      sized_header_entries := List column_count:
        entry := header[it]
        entry + " " * (column_sizes[it] - entry.size)
      print_ "│ $(sized_header_entries.join "   ") │"
      print_ "├─$(bars.join "─┼─")─┤"

    rows.do: | row |
      sized_row_entries := List column_count:
        entry := row[it]
        entry + " " * (column_sizes[it] - entry.size)
      print_ "│ $(sized_row_entries.join "   ") │"
    print_ "└─$(bars.join "─┴─")─┘"

  info_map map/Map --indentation/string="":
    map.do: | key value |
      if value is Map:
        print_ "$indentation$key:"
        info_map value --indentation="$indentation  "
      else:
        print_ "$indentation$key: $value"

  print_ str/string:
    global_print_ str

  abort -> none:
    exit 1
