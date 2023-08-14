// Copyright (C) 2022 Toitware ApS. All rights reserved.

import expect show *
import artemis.shared.json-diff show Modification

main:
  test-stringify

  test-no-change null
  test-no-change false
  test-no-change 42
  test-no-change 87.3
  test-no-change "biz"
  test-no-change [7, 9, 13]

  test-value-change 42 87
  test-value-change null 87
  test-value-change 42 null
  test-value-change 42 "kurt"
  test-value-change "kurt" true
  test-value-change "kurt" [1, 2, 3]
  test-value-change [1, 2, 3] [1, 2]

  test-map-change
  test-nested-change
  test-copy-and-modify

test-stringify:
  test-stringify "{ foo: ~42 }" --from={"foo":42} --to={:}
  test-stringify "{ bar: +{foo: 87}, foo: ~42 }" --from={"foo":42} --to={"bar":{"foo":87}}
  test-stringify "{ bar: { foo: 42->87 } }" --from={"bar":{"foo":42}} --to={"bar":{"foo":87}}

test-stringify expected/string --from/Map --to/Map:
  modification/Modification? := Modification.compute --from=from --to=to
  actual/string := Modification.stringify modification
  expect-equals expected actual

test-no-change value/any:
  copy ::= value is List ? value.copy : value
  expect-null
      Modification.compute --from={"foo": value} --to={"foo": copy}

class Calls:
  expected_/int
  actual_/int := 0
  constructor .expected_:
  up -> none:
    actual_++
  validate -> none:
    expect-equals expected_ actual_

callbacks expected/int [block]:
  calls := Calls expected
  try:
    block.call calls
  finally:
    calls.validate

test-value-change expected-from/any expected-to/any:
  modification/Modification? := null
  modification = Modification.compute --from={:} --to={"foo": expected-to}
  callbacks 1: | calls | modification.on-value
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect-structural-equals {:} from
        expect-structural-equals {"foo": expected-to} to
        calls.up

  modification = Modification.compute --from={:} --to={"foo": expected-to}
  callbacks 1: | calls | modification.on-value "foo"
      --added=: | to |
        expect-structural-equals expected-to to
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"bar":expected-from} --to={:}
  callbacks 1: | calls | modification.on-value "bar"
      --added=: expect false
      --removed=: | from |
        expect-structural-equals expected-from from
        calls.up
      --updated=: expect false

  modification = Modification.compute --from={"baz":expected-from} --to={"baz":expected-to}
  callbacks 1: | calls | modification.on-value "baz"
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect-structural-equals expected-from from
        expect-structural-equals expected-to to
        calls.up

  modification = Modification.compute --from={"baz":expected-from} --to={"baz":expected-to}
  callbacks 2: | calls | modification.on-value "baz"
      --added=:
        expect-structural-equals expected-to it
        calls.up
      --removed=:
        expect-structural-equals expected-from it
        calls.up

test-map-change:
  test-map-no-change
  test-map-added
  test-map-removed
  test-map-updated
  test-map-extras

test-map-extras:
  modification/Modification? := null
  modification = Modification.compute --from={:} --to={"foo": 42}
  callbacks 1: | calls | modification.on-map
      --added=: | key/string value |
        expect-equals "foo" key
        expect-equals 42 value
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"bar": 42} --to={"bar": 87}
  callbacks 1: | calls | modification.on-value
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect-structural-equals {"bar": 42} from
        expect-structural-equals {"bar": 87} to
        calls.up

  modification = Modification.compute --from={"foo": {"bar": 42}} --to={"foo": {"bar": 87}}
  callbacks 1: | calls | modification.on-value "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect-structural-equals {"bar": 42} from
        expect-structural-equals {"bar": 87} to
        calls.up

test-map-no-change:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {:}} --to={"foo": {:}}
  expect-null modification

test-map-added:
  modification/Modification? := null
  modification = Modification.compute --from={:} --to={"bar": 42}
  callbacks 1: | calls | modification.on-map
      --added=: | key to |
        expect-equals "bar" key
        expect-structural-equals 42 to
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"foo": {:}} --to={"foo": {"bar": 42}}
  callbacks 1: | calls | modification.on-map "foo"
      --added=: | key to |
        expect-equals "bar" key
        expect-structural-equals 42 to
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={"foo": {"baz": 0}} --to={"foo": {"baz": 0, "bar": 88}}
  callbacks 1: | calls | modification.on-map "foo"
      --added=: | key to |
        expect-equals "bar" key
        expect-structural-equals 88 to
        calls.up
      --removed=: expect false
      --updated=: expect false

  modification = Modification.compute --from={:} --to={"foo": {"bar": 42}}
  callbacks 1: | calls | modification.on-map "foo"
      --added=: | key to |
        expect-equals "bar" key
        expect-structural-equals 42 to
        calls.up
      --removed=:
        expect false
      --updated=:
        expect false

  modification = Modification.compute --from={"foo": 87} --to={"foo": {"bar": 42}}
  callbacks 1: | calls | modification.on-map "foo"
      --added=: | key to |
        expect-equals "bar" key
        expect-structural-equals 42 to
        calls.up
      --removed=: expect false
      --updated=: expect false

test-map-removed:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {:}}
  callbacks 1: | calls | modification.on-map "foo"
      --added=: expect false
      --removed=: | key from |
        expect-equals "bar" key
        expect-structural-equals 87 from
        calls.up
      --updated=: expect false

  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": false}
  callbacks 1: | calls | modification.on-map "foo"
      --added=: expect false
      --removed=: | key from |
        expect-equals "bar" key
        expect-structural-equals 87 from
        calls.up
      --updated=: expect false

  modification = Modification.compute --from={"foo": {"bar": 87, "baz": 99}} --to={"foo": false}
  callbacks 2: | calls | modification.on-map "foo"
      --added=: expect false
      --removed=: | key from |
        calls.up
      --updated=: expect false

test-map-updated:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {"bar": 99}}
  callbacks 1: | calls | modification.on-map "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | key from to |
        expect-equals "bar" key
        expect-structural-equals 87 from
        expect-structural-equals 99 to
        calls.up

  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {"bar": 99}}
  callbacks 2: | calls | modification.on-map "foo"
      --added=: | key to |
        expect-equals "bar" key
        expect-structural-equals 99 to
        calls.up
      --removed=: | key from |
        expect-equals "bar" key
        expect-structural-equals 87 from
        calls.up

test-nested-change:
  modification/Modification? := null
  modification = Modification.compute --from={"foo": {"bar": 87}} --to={"foo": {"bar": 99}}
  callbacks 3: | calls | modification.on-value "foo"
      --added=: expect false
      --removed=: expect false
      --modified=: | nested/Modification |
        nested.on-value "bar"
            --added=:
              expect-structural-equals 99 it
              calls.up
            --removed=:
              expect-structural-equals 87 it
              calls.up
        calls.up
  callbacks 2: | calls | modification.on-map "foo"
      --added=: | key value |
        expect-equals "bar" key
        expect-structural-equals 99 value
        calls.up
      --removed=: | key value |
        expect-equals "bar" key
        expect-structural-equals 87 value
        calls.up
      --modified=: expect false

  modification = Modification.compute
      --from = {"foo": {"bar": {"id": 42}}}
      --to   = {"foo": {"bar": {"id": 21}}}
  callbacks 1: | calls | modification.on-value "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | from to |
        expect-structural-equals {"bar": {"id": 42}} from
        expect-structural-equals {"bar": {"id": 21}} to
        calls.up
  callbacks 1: | calls | modification.on-map "foo"
      --added=: expect false
      --removed=: expect false
      --updated=: | key from to |
        expect-equals key "bar"
        expect-structural-equals {"id": 42} from
        expect-structural-equals {"id": 21} to
        calls.up
  callbacks 3: | calls | modification.on-map "foo"
      --added=: expect false
      --removed=: expect false
      --modified=: | key nested/Modification |
        expect-equals key "bar"
        nested.on-value "id"
            --added=:
              expect-equals 21 it
              calls.up
            --removed=:
              expect-equals 42 it
              calls.up
        calls.up

deep-copy value/any -> any:
  if value is List:
    return List value.size: deep-copy value[it]
  else if value is Map:
    copy := {:}
    value.do: | key value |
      copy[key] = deep-copy value
    return copy
  else:
    return value

test-copy-and-modify:
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

  updated = deep-copy original
  updated["apps"]["hest"]["id"] = 99
  modification = Modification.compute --from=original --to=updated
  callbacks 3: | calls | modification.on-map "apps"
      --added=: expect false
      --removed=: expect false
      --modified=: | key/string nested/Modification |
        expect-equals "hest" key
        nested.on-map
            --added=: expect false
            --removed=: expect false
            --updated=: | key from to |
              expect-equals "id" key
              expect-equals 42 from
              expect-equals 99 to
              calls.up
        nested.on-value "id"
            --added=: expect false
            --removed=: expect false
            --updated=: | from to |
              expect-equals 42 from
              expect-equals 99 to
              calls.up
        calls.up

  updated = deep-copy original
  updated["apps"]["hest"]["id"] = 101
  modification = Modification.compute --from=original --to=updated
  callbacks 8: | calls | modification.on-value "apps"
      --added=: expect false
      --removed=: expect false
      --modified=: | nested/Modification |
        nested.on-map
            --added=: expect false
            --removed=: expect false
            --updated=: | key from to |
              expect-equals "hest" key
              expect-structural-equals {"id": 42, "triggers": [0, 2]} from
              expect-structural-equals {"id": 101, "triggers": [0, 2]} to
              calls.up
        nested.on-map
            --added=: expect false
            --removed=: expect false
            --modified=: | key inner/Modification |
              expect-equals "hest" key
              inner.on-value
                 --added=: | value |
                   expect-structural-equals {"id": 101, "triggers": [0, 2]} value
                   calls.up
                 --removed=: | value |
                   expect-structural-equals {"id": 42, "triggers": [0, 2]} value
                   calls.up
              inner.on-value "id"
                 --added=: | value |
                   expect-equals 101 value
                   calls.up
                 --removed=: | value |
                   expect-equals 42 value
                   calls.up
              calls.up
        nested.on-map "hest"
            --added=: expect false
            --removed=: expect false
            --updated=: | key from to |
              expect-equals "id" key
              expect-equals 42 from
              expect-equals 101 to
              calls.up
        calls.up

  updated = deep-copy original
  updated["apps"]["hest"]["triggers"][0] = 17
  modification = Modification.compute --from=original --to=updated
  callbacks 2: | calls | modification.on-map "apps"
      --added=: expect false
      --removed=: expect false
      --modified=: | key/string nested/Modification |
        nested.on-value "triggers"
            --added=: expect false
            --removed=: expect false
            --updated=: | from to |
              expect-structural-equals [0, 2] from
              expect-structural-equals [17, 2] to
              calls.up
        calls.up

  updated = deep-copy original
  updated["apps"]["hest"]["triggers"].add 17
  updated["apps"]["fisk"]["triggers"].add 17
  modification = Modification.compute --from=original --to=updated
  callbacks 4: | calls | modification.on-map "apps"
      --added=: expect false
      --removed=: expect false
      --modified=: | key/string nested/Modification |
        nested.on-value "triggers"
            --added=: expect false
            --removed=: expect false
            --updated=: | from to |
              expect-equals 17 to.last
              calls.up
        calls.up
