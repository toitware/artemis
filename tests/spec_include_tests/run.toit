// Copyright (C) 2023 Toitware ApS.

import artemis.cli.pod_specification show PodSpecification PodSpecificationException
import artemis.cli.utils show read_json
import artemis.shared.json_diff show json_equals

import expect show *

import host.file

main args:
  test := args[0]
  expected := args[1]
  fail := args[2]

  if file.is_file expected:
    run_test test expected
  else if file.is_file fail:
    run_negative_test test fail
  else:
    throw "Expected file or fail file not found"

run_test test/string expected/string:
  actual_json := PodSpecification.parse_json_hierarchy test
  expected_json := read_json expected

  expect (json_equals expected_json actual_json)

run_negative_test test/string fail/string:
  exception := catch:
    PodSpecification.parse_json_hierarchy test
  expect_not_null exception
  expect exception is PodSpecificationException
  expected_message := (file.read_content fail).to_string
  expected_message = expected_message.replace --all "\r\n" "\n"
  expected_message = expected_message.trim
  actual_message := (exception as PodSpecificationException).message
  actual_message = actual_message.replace --all "\r\n" "\n"
  actual_message = actual_message.trim
  expect_equals expected_message actual_message
