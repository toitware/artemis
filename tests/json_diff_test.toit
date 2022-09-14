// Copyright (C) 2022 Toitware ApS. All rights reserved.

import expect show *
import artemis.shared.json_diff show Modification

main:
  test_stringify

  test_no_change null
  test_no_change false
  test_no_change 42
  test_no_change 87.3
  test_no_change "biz"
  test_no_change [7, 9, 13]

  test_value_change 42 87
  test_value_change null 87
  test_value_change 42 null
  test_value_change 42 "kurt"
  test_value_change "kurt" true
  test_value_change "kurt" [1, 2, 3]
  test_value_change [1, 2, 3] [1, 2]

  test_map_change
  test_nested_change
  test_copy_and_modify

test_stringify:
  test_stringify "{ foo: ~42 }" --from={"foo":42} --to={:}
  test_stringify "{ bar: +{foo: 87}, foo: ~42 }" --from={"foo":42} --to={"bar":{"foo":87}}
  test_stringify "{ bar: { foo: 42->87 } }" --from={"bar":{"foo":42}} --to={"bar":{"foo":87}}

test_stringify expected/string --from/Map --to/Map:
  modification/Modification? := Modification.compute --from=from --to=to
  actual/string := Modification.stringify modification
  expect_equals expected actual

test_no_change value/any:
  copy ::= value is List ? value.copy : value
  expect_null
      Modification.compute --from={"foo": value} --to={"foo": copy}

class Calls:
  expected_/int
  actual_/int := 0
  constructor .expected_:
  up -> none:
    actual_++
  validate -> none:
    expect_equals expected_ actual_

callbacks expected/int [block]:
  calls := Calls expected
  try:
    block.call calls
  finally:
    calls.validate

test_value_change expected_from/any expected_to/any:
  modification/Modification? := null
  modification = Modification.compute --from={:} --to={"foo": expected_to}
  callbacks 1: | calls | modification.on_value
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect_structural_equals {:} from
        expect_structural_equals {"foo": expected_to} to
        calls.up

  modification = Modification.compute --from={:} --to={"foo": expected_to}
  callbacks 1: | calls | modification.on_value "foo"
      --added=: | to |
        expect_structural_equals expected_to to
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"bar":expected_from} --to={:}
  callbacks 1: | calls | modification.on_value "bar"
      --added=: expect false
      --removed=: | from |
        expect_structural_equals expected_from from
        calls.up
      --updated=: expect false

  modification = Modification.compute --from={"baz":expected_from} --to={"baz":expected_to}
  callbacks 1: | calls | modification.on_value "baz"
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect_structural_equals expected_from from
        expect_structural_equals expected_to to
        calls.up

  modification = Modification.compute --from={"baz":expected_from} --to={"baz":expected_to}
  callbacks 2: | calls | modification.on_value "baz"
      --added=:
        expect_structural_equals expected_to it
        calls.up
      --removed=:
        expect_structural_equals expected_from it
        calls.up

test_map_change:
  test_map_no_change
  test_map_added
  test_map_removed
  test_map_updated
  test_map_extras

test_map_extras:
  modification/Modification? := null
  modification = Modification.compute --from={:} --to={"foo": 42}
  callbacks 1: | calls | modification.on_map
      --added=: | key/string value |
        expect_equals "foo" key
        expect_equals 42 value
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"bar": 42} --to={"bar": 87}
  callbacks 1: | calls | modification.on_value
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect_structural_equals {"bar": 42} from
        expect_structural_equals {"bar": 87} to
        calls.up

  modification = Modification.compute --from={"foo": {"bar": 42}} --to={"foo": {"bar": 87}}
  callbacks 1: | calls | modification.on_value "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect_structural_equals {"bar": 42} from
        expect_structural_equals {"bar": 87} to
        calls.up

test_map_no_change:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {:}} --to={"foo": {:}}
  expect_null modification

test_map_added:
  modification/Modification? := null
  modification = Modification.compute --from={:} --to={"bar": 42}
  callbacks 1: | calls | modification.on_map
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 42 to
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"foo": {:}} --to={"foo": {"bar": 42}}
  callbacks 1: | calls | modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 42 to
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"foo": {"baz": 0}} --to={"foo": {"baz": 0, "bar": 88}}
  callbacks 1: | calls | modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 88 to
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={:} --to={"foo": {"bar": 42}}
  callbacks 1: | calls | modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 42 to
        calls.up
      --removed=:
        expect false
      --updated=:
        expect false

  modification = Modification.compute --from={"foo": 87} --to={"foo": {"bar": 42}}
  callbacks 1: | calls | modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 42 to
        calls.up
      --removed=: expect false
      --updated=: expect false

test_map_removed:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {:}}
  callbacks 1: | calls | modification.on_map "foo"
      --added=: expect false
      --removed=: | key from |
        expect_equals "bar" key
        expect_structural_equals 87 from
        calls.up
      --updated=: expect false

  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": false}
  callbacks 1: | calls | modification.on_map "foo"
      --added=: expect false
      --removed=: | key from |
        expect_equals "bar" key
        expect_structural_equals 87 from
        calls.up
      --updated=: expect false

  modification = Modification.compute --from={"foo": {"bar": 87, "baz": 99}} --to={"foo": false}
  callbacks 2: | calls | modification.on_map "foo"
      --added=: expect false
      --removed=: | key from |
        calls.up
      --updated=: expect false

test_map_updated:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {"bar": 99}}
  callbacks 1: | calls | modification.on_map "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | key from to |
        expect_equals "bar" key
        expect_structural_equals 87 from
        expect_structural_equals 99 to
        calls.up

  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {"bar": 99}}
  callbacks 2: | calls | modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 99 to
        calls.up
      --removed=: | key from |
        expect_equals "bar" key
        expect_structural_equals 87 from
        calls.up

test_nested_change:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {"bar": 99}}
  callbacks 3: | calls | modification.on_value "foo"
      --added=: expect false
      --removed=: expect false
      --modified=: | nested/Modification |
        nested.on_value "bar"
            --added=:
              expect_structural_equals 99 it
              calls.up
            --removed=:
              expect_structural_equals 87 it
              calls.up
        calls.up
  callbacks 2: | calls | modification.on_map "foo"
      --added=: | key value |
        expect_equals "bar" key
        expect_structural_equals 99 value
        calls.up
      --removed=: | key value |
        expect_equals "bar" key
        expect_structural_equals 87 value
        calls.up
      --modified=: expect false

  modification = Modification.compute
      --from = {"foo": {"bar": {"id": 42}}}
      --to   = {"foo": {"bar": {"id": 21}}}
  callbacks 1: | calls | modification.on_value "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect_structural_equals {"bar": {"id": 42}} from
        expect_structural_equals {"bar": {"id": 21}} to
        calls.up
  callbacks 1: | calls | modification.on_map "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | key from to |
        expect_equals key "bar"
        expect_structural_equals {"id": 42} from
        expect_structural_equals {"id": 21} to
        calls.up
  callbacks 3: | calls | modification.on_map "foo"
      --added=: expect false
      --removed=: expect false
      --modified=: | key nested/Modification |
        expect_equals key "bar"
        nested.on_value "id"
            --added=:
              expect_equals 21 it
              calls.up
            --removed=:
              expect_equals 42 it
              calls.up
        calls.up

deep_copy value/any -> any:
  if value is List:
    return List value.size: deep_copy value[it]
  else if value is Map:
    copy := {:}
    value.do: | key value |
      copy[key] = deep_copy value
    return copy
  else:
    return value

test_copy_and_modify:
  original ::= {
    "apps": {
      "hest": {
        "id": 42,
        "triggers": [0, 2],
      },
      "fisk": {
        "id": 87,
        "triggers": [0, 3, 7, 1]
      }
    }
  }

  modification/Modification? := null
  updated := null

  updated = deep_copy original
  updated["apps"]["hest"]["id"] = 99
  modification = Modification.compute --from=original --to=updated
  callbacks 3: | calls | modification.on_map "apps"
      --added=: expect false
      --removed=: expect false
      --modified=: | key/string nested/Modification |
        expect_equals "hest" key
        nested.on_map
            --added=: expect false
            --removed=: expect false
            --updated=: | key from to |
              expect_equals "id" key
              expect_equals 42 from
              expect_equals 99 to
              calls.up
        nested.on_value "id"
            --added=: expect false
            --removed=: expect false
            --updated=: | from to |
              expect_equals 42 from
              expect_equals 99 to
              calls.up
        calls.up

  updated = deep_copy original
  updated["apps"]["hest"]["id"] = 101
  modification = Modification.compute --from=original --to=updated
  callbacks 8: | calls | modification.on_value "apps"
      --added=: expect false
      --removed=: expect false
      --modified=: | nested/Modification |
        nested.on_map
            --added=: expect false
            --removed=: expect false
            --updated=: | key from to |
              expect_equals "hest" key
              expect_structural_equals {"id": 42, "triggers": [0, 2]} from
              expect_structural_equals {"id": 101, "triggers": [0, 2]} to
              calls.up
        nested.on_map
            --added=: expect false
            --removed=: expect false
            --modified=: | key inner/Modification |
              expect_equals "hest" key
              inner.on_value
                 --added=: | value |
                   expect_structural_equals {"id": 101, "triggers": [0, 2]} value
                   calls.up
                 --removed=: | value |
                   expect_structural_equals {"id": 42, "triggers": [0, 2]} value
                   calls.up
              inner.on_value "id"
                 --added=: | value |
                   expect_equals 101 value
                   calls.up
                 --removed=: | value |
                   expect_equals 42 value
                   calls.up
              calls.up
        nested.on_map "hest"
            --added=: expect false
            --removed=: expect false
            --updated=: | key from to |
              expect_equals "id" key
              expect_equals 42 from
              expect_equals 101 to
              calls.up
        calls.up

  updated = deep_copy original
  updated["apps"]["hest"]["triggers"][0] = 17
  modification = Modification.compute --from=original --to=updated
  callbacks 2: | calls | modification.on_map "apps"
      --added=: expect false
      --removed=: expect false
      --modified=: | key/string nested/Modification |
        nested.on_value "triggers"
            --added=: expect false
            --removed=: expect false
            --updated=: | from to |
              expect_structural_equals [0, 2] from
              expect_structural_equals [17, 2] to
              calls.up
        calls.up

  updated = deep_copy original
  updated["apps"]["hest"]["triggers"].add 17
  updated["apps"]["fisk"]["triggers"].add 17
  modification = Modification.compute --from=original --to=updated
  callbacks 4: | calls | modification.on_map "apps"
      --added=: expect false
      --removed=: expect false
      --modified=: | key/string nested/Modification |
        nested.on_value "triggers"
            --added=: expect false
            --removed=: expect false
            --updated=: | from to |
              expect_equals 17 to.last
              calls.up
        calls.up
