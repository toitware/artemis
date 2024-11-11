// Copyright (C) 2023 Toitware ApS.

import artemis.cli.pod-specification show PodSpecification PodSpecificationException
import artemis.cli.utils show read-json write-json-to-file write-blob-to-file
import artemis.shared.json-diff show json-equals

import expect show *

import host.file
import host.os

main args:
  arg-index := 0
  test := args[arg-index++]
  expected := args[arg-index++]
  fail := args[arg-index++]

  should-update := os.env.contains "UPDATE_GOLD"

  if file.is-file expected:
    run-test test expected --should-update=should-update
  else if file.is-file fail:
    run-negative-test test fail --should-update=should-update
  else:
    throw "Expected-file or fail-file not found"

run-test test/string expected-path/string --should-update/bool:
  actual-json := PodSpecification.parse-json-hierarchy test
  if should-update:
    write-json-to-file --pretty expected-path actual-json
    return

  expected-json := read-json expected-path
  expect (json-equals expected-json actual-json)

run-negative-test test/string fail-path/string --should-update/bool:
  exception := catch:
    PodSpecification.parse-json-hierarchy test
  expect-not-null exception
  actual-message := (exception as PodSpecificationException).message
  actual-message = actual-message.replace --all "\r\n" "\n"

  if should-update:
    write-blob-to-file fail-path actual-message
    return

  actual-message = actual-message.trim

  expect exception is PodSpecificationException
  expected-message := (file.read-contents fail-path).to-string
  expected-message = expected-message.replace --all "\r\n" "\n"
  expected-message = expected-message.trim
  expect-equals expected-message actual-message
