// Copyright (C) 2023 Toitware ApS. All rights reserved.

import artemis.cli.pod_registry show PodReference
import expect show *

main:
  reference := PodReference.parse "foo@bar" --on_error=: throw it
  expect_equals "foo" reference.name
  expect_equals "bar" reference.tag

  expect_throw "Cannot specify both revision and tag: 'foo@bar#baz'.":
    PodReference.parse "foo@bar#baz" --on_error=: throw it

  reference = PodReference.parse "foo#123" --on_error=: throw it
  expect_equals "foo" reference.name
  expect_equals 123 reference.revision

  expect_throw "Invalid revision: 'bar'.":
    PodReference.parse "foo#bar" --on_error=: throw it

  uuid_string := "01234567-89ab-cdef-0123-456789abcdef"
  reference = PodReference.parse uuid_string --on_error=: throw it
  expect_equals uuid_string "$reference.id"

  expect_throw "Invalid pod reference: 'foo'.":
    PodReference.parse "foo" --on_error=: throw it

  reference = PodReference.parse "foo" --allow_name_only --on_error=: throw it
  expect_equals "foo" reference.name

  expect_throw "Invalid pod reference: 'foo'.":
    PodReference.parse "foo" --on_error=: throw it

  reference = PodReference.parse "foo@bar@baz" --on_error=: throw it
  expect_equals "foo" reference.name
  expect_equals "bar@baz" reference.tag
