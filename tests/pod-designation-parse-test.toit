// Copyright (C) 2023 Toitware ApS. All rights reserved.

import artemis.cli.pod-registry show PodReference
import expect show *

main:
  reference := PodReference.parse "foo@bar" --on-error=: throw it
  expect-equals "foo" reference.name
  expect-equals "bar" reference.tag

  expect-throw "Cannot specify both revision and tag: 'foo@bar#baz'.":
    PodReference.parse "foo@bar#baz" --on-error=: throw it

  reference = PodReference.parse "foo#123" --on-error=: throw it
  expect-equals "foo" reference.name
  expect-equals 123 reference.revision

  expect-throw "Invalid revision: 'bar'.":
    PodReference.parse "foo#bar" --on-error=: throw it

  uuid-string := "01234567-89ab-cdef-0123-456789abcdef"
  reference = PodReference.parse uuid-string --on-error=: throw it
  expect-equals uuid-string "$reference.id"

  expect-throw "Invalid pod reference: 'foo'.":
    PodReference.parse "foo" --on-error=: throw it

  reference = PodReference.parse "foo" --allow-name-only --on-error=: throw it
  expect-equals "foo" reference.name

  expect-throw "Invalid pod reference: 'foo'.":
    PodReference.parse "foo" --on-error=: throw it

  reference = PodReference.parse "foo@bar@baz" --on-error=: throw it
  expect-equals "foo" reference.name
  expect-equals "bar@baz" reference.tag
