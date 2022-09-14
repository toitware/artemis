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

  modification/Modification? := null
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
              expect_equals 99 it
              calls.up
            --removed=:
              expect_equals 87 it
              calls.up
        calls.up
  callbacks 2: | calls | modification.on_map "foo"
      --added=:
        expect_equals "bar" it
        calls.up
      --removed=:
        expect_equals "bar" it
        calls.up
      --modified=: expect false

  modification = Modification.compute
      --from = {"foo": {"bar": {"id": 42}}}
      --to   = {"foo": {"bar": {"id": 21}}}
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
