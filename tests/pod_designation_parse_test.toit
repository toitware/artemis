// Copyright (C) 2023 Toitware ApS. All rights reserved.

import artemis.cli.pod_registry show PodDesignation
import expect show *

main:
  designation := PodDesignation.parse "foo@bar" --on_error=: throw it
  expect_equals "foo" designation.name
  expect_equals "bar" designation.tag

  expect_throw "Cannot specify both revision and tag: 'foo@bar#baz'.":
    PodDesignation.parse "foo@bar#baz" --on_error=: throw it

  designation = PodDesignation.parse "foo#123" --on_error=: throw it
  expect_equals "foo" designation.name
  expect_equals 123 designation.revision

  expect_throw "Invalid revision: 'bar'.":
    PodDesignation.parse "foo#bar" --on_error=: throw it

  uuid_string := "01234567-89ab-cdef-0123-456789abcdef"
  designation = PodDesignation.parse uuid_string --on_error=: throw it
  expect_equals uuid_string "$designation.id"

  expect_throw "Invalid pod designation: 'foo'.":
    PodDesignation.parse "foo" --on_error=: throw it

  designation = PodDesignation.parse "foo" --allow_name_only --on_error=: throw it
  expect_equals "foo" designation.name

  expect_throw "Invalid pod designation: 'foo'.":
    PodDesignation.parse "foo" --on_error=: throw it

  designation = PodDesignation.parse "foo@bar@baz" --on_error=: throw it
  expect_equals "foo" designation.name
  expect_equals "bar@baz" designation.tag
