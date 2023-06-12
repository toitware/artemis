// Copyright (C) 2023 Toitware ApS.

import artemis.cli.pod_specification show PodSpecification PodSpecificationException
import artemis.cli.utils show read_json write_json_to_file write_blob_to_file
import artemis.shared.json_diff show json_equals

import expect show *

import host.file
import host.os

main args:
  arg_index := 0
  test := args[arg_index++]
  expected := args[arg_index++]
  fail := args[arg_index++]

  should_update := os.env.contains "UPDATE_GOLD"

  if file.is_file expected:
    run_test test expected --should_update=should_update
  else if file.is_file fail:
    run_negative_test test fail --should_update=should_update
  else:
    throw "Expected-file or fail-file not found"

run_test test/string expected_path/string --should_update/bool:
  actual_json := PodSpecification.parse_json_hierarchy test
  if should_update:
    write_json_to_file --pretty expected_path actual_json
    return

  expected_json := read_json expected_path
  expect (json_equals expected_json actual_json)

run_negative_test test/string fail_path/string --should_update/bool:
  exception := catch:
    PodSpecification.parse_json_hierarchy test
  expect_not_null exception
  actual_message := (exception as PodSpecificationException).message
  actual_message = actual_message.replace --all "\r\n" "\n"

  if should_update:
    write_blob_to_file fail_path actual_message
    return

  actual_message = actual_message.trim

  expect exception is PodSpecificationException
  expected_message := (file.read_content fail_path).to_string
  expected_message = expected_message.replace --all "\r\n" "\n"
  expected_message = expected_message.trim
  expect_equals expected_message actual_message
