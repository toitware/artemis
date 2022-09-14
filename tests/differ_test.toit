// Copyright (C) 2022 Toitware ApS. All rights reserved.

import expect show *
import artemis.shared.differ show *

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

test_value_change expected_from/any expected_to/any:
  modification/Modification? := null
  modification = Modification.compute --from={:} --to={"foo": expected_to}
  modification.on_value "foo"
      --added=: | to |
        expect_structural_equals expected_to to
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"bar":expected_from} --to={:}
  modification.on_value "bar"
      --added=: expect false
      --removed=: | from |
        expect_structural_equals expected_from from
      --updated=: expect false

  modification = Modification.compute --from={"baz":expected_from} --to={"baz":expected_to}
  modification.on_value "baz"
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect_structural_equals expected_from from
        expect_structural_equals expected_to to

  modification = Modification.compute --from={"baz":expected_from} --to={"baz":expected_to}
  modification.on_value "baz"
      --added=: expect_structural_equals expected_to it
      --removed=: expect_structural_equals expected_from it

test_map_change:
  test_map_no_change
  test_map_added
  test_map_removed
  test_map_updated

  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 42}} --to={"foo": {"bar": 87}}
  modification.on_value "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect_structural_equals {"bar": 42} from
        expect_structural_equals {"bar": 87} to

test_map_no_change:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {:}} --to={"foo": {:}}
  expect_null modification

test_map_added:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {:}} --to={"foo": {"bar": 42}}
  modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 42 to
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"foo": {"baz": 0}} --to={"foo": {"baz": 0, "bar": 88}}
  modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 88 to
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={:} --to={"foo": {"bar": 42}}
  modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 42 to
      --removed=:
        expect false
      --updated=:
        expect false

  modification = Modification.compute --from={"foo": 87} --to={"foo": {"bar": 42}}
  modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 42 to
      --removed=: expect false
      --updated=: expect false

test_map_removed:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {:}}
  modification.on_map "foo"
      --added=: expect false
      --removed=: | key from |
        expect_equals "bar" key
        expect_structural_equals 87 from
      --updated=: expect false

  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": false}
  modification.on_map "foo"
      --added=: expect false
      --removed=: | key from |
        expect_equals "bar" key
        expect_structural_equals 87 from
      --updated=: expect false

test_map_updated:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {"bar": 99}}
  modification.on_map "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | key from to |
        expect_equals "bar" key
        expect_structural_equals 87 from
        expect_structural_equals 99 to

  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {"bar": 99}}
  modification.on_map "foo"
      --added=: | key to |
        expect_equals "bar" key
        expect_structural_equals 99 to
      --removed=: | key from |
        expect_equals "bar" key
        expect_structural_equals 87 from

test_nested_change:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {"bar": 99}}
  modification.on_value "foo"
      --added=: expect false
      --removed=: expect false
      --modified=: | nested/Modification |
        nested.on_value "bar"
            --added=: expect_equals 99 it
            --removed=: expect_equals 87 it
  modification.on_map "foo"
      --added=: expect_equals "bar" it
      --removed=: expect_equals "bar" it
      --modified=: expect false

  modification = Modification.compute
      --from = {"foo": {"bar": {"id": 42}}}
      --to   = {"foo": {"bar": {"id": 21}}}
  modification.on_map "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | key from to |
        expect_equals key "bar"
        expect_structural_equals {"id": 42} from
        expect_structural_equals {"id": 21} to
  modification.on_map "foo"
      --added=: expect false
      --removed=: expect false
      --modified=: | key nested/Modification |
        expect_equals key "bar"
        nested.on_value "id"
            --added=: expect_equals 21 it
            --removed=: expect_equals 42 it
