// Copyright (C) 2023 Toitware ApS. All rights reserved.

import expect show *

import artemis.cli.pod_specification
  show
    PodSpecification
    PodSpecificationException
    INITIAL_POD_SPECIFICATION
    EXAMPLE_POD_SPECIFICATION

import .utils

main:
  test_examples
  test_custom_envelope
  test_errors

test_examples:
  PodSpecification.from_json INITIAL_POD_SPECIFICATION --path="ignored"
  PodSpecification.from_json EXAMPLE_POD_SPECIFICATION --path="ignored"

expect_format_error str/string json/Map:
  exception := catch: PodSpecification.from_json json --path="ignored"
  expect exception is PodSpecificationException
  expect_equals str exception.message
  expect_equals str "$exception"

VALID_SPECIFICATION ::= {
  "version": 1,
  "name": "test-pod",
  "sdk-version": "1.0.0",
  "artemis-version": "1.0.0",
  "max-offline": "1h",
  "connections": [
    {
      "type": "wifi",
      "ssid": "ssid",
      "password": "password",
    },
  ],
  "containers": {
    "app1": {
      "entrypoint": "entrypoint.toit",
    },
    "app2": {
      "entrypoint": "entrypoint.toit",
      "git": "foo",
      "branch": "bar",
    },
    "app3": {
      "snapshot": "foo.snapshot",
    },
    "app4": {
      "entrypoint": "entrypoint.toit",
      "triggers": [
        { "interval": "5s" },
        "boot",
        "install",
      ]
    },
    "app5": {
      "entrypoint": "entrypoint.toit",
      "defines": {
        "foo": 17,
        "bar": "42"
      }
    }
  }
}

new_valid -> Map:
  return deep_copy_ VALID_SPECIFICATION

test_custom_envelope:
  custom_envelope := new_valid
  custom_envelope["firmware-envelope"] = "envelope-path"
  custom_envelope.remove "sdk-version"
  pod := PodSpecification.from_json custom_envelope --path="ignored"
  expect_equals "envelope-path" pod.envelope

  version_and_envelope := new_valid
  version_and_envelope["firmware-envelope"] = "envelope-path"
  pod = PodSpecification.from_json version_and_envelope --path="ignored"
  expect_equals "envelope-path" pod.envelope
  expect_equals "1.0.0" pod.sdk_version

test_errors:
  no_version := new_valid
  no_version.remove "version"
  expect_format_error
      "Missing version in pod specification."
      no_version

  no_name := new_valid
  no_name.remove "name"
  expect_format_error
      "Missing name in pod specification."
      no_name

  no_sdk_version := new_valid
  no_sdk_version.remove "sdk-version"
  expect_format_error
      "Neither 'sdk-version' nor 'firmware-envelope' are present in pod specification."
      no_sdk_version

  no_artemis_version := new_valid
  no_artemis_version.remove "artemis-version"
  expect_format_error
      "Missing artemis-version in pod specification."
      no_artemis_version

  no_max_offline := new_valid
  no_max_offline.remove "max-offline"
  no_max_offline_spec := PodSpecification.from_json no_max_offline --path="ignored"
  expect_equals 0 no_max_offline_spec.max_offline_seconds

  no_connections := new_valid
  no_connections.remove "connections"
  expect_format_error
      "Missing connections in pod specification."
      no_connections

  no_containers := new_valid
  no_containers.remove "containers"
  // Should work without error.
  PodSpecification.from_json no_containers --path="ignored"

  both_apps_and_containers := new_valid
  both_apps_and_containers["apps"] = both_apps_and_containers["containers"]
  expect_format_error
      "Both 'apps' and 'containers' are present in pod specification."
      both_apps_and_containers

  invalid_version := new_valid
  invalid_version["version"] = 2
  expect_format_error
      "Unsupported pod specification version 2"
      invalid_version

  invalid_containers := new_valid
  invalid_containers["containers"] = 1
  expect_format_error
      "Entry containers in pod specification is not a map: 1"
      invalid_containers

  invalid_container := new_valid
  invalid_container["containers"]["app1"] = 1
  expect_format_error
      "Container app1 in pod specification is not a map: 1"
      invalid_container

  invalid_connections := new_valid
  invalid_connections["connections"] = 1
  expect_format_error
      "Entry connections in pod specification is not a list: 1"
      invalid_connections

  invalid_connection := new_valid
  invalid_connection["connections"][0] = 1
  expect_format_error
      "Connection in pod specification is not a map: 1"
      invalid_connection

  no_type := new_valid
  no_type["connections"][0].remove "type"
  expect_format_error
      "Missing type in connection."
      no_type

  invalid_type := new_valid
  invalid_type["connections"][0]["type"] = "invalid"
  expect_format_error
      "Unknown connection type: invalid"
      invalid_type

  no_ssid := new_valid
  no_ssid["connections"][0].remove "ssid"
  expect_format_error
      "Missing ssid in wifi connection."
      no_ssid

  no_password := new_valid
  no_password["connections"][0].remove "password"
  expect_format_error
      "Missing password in wifi connection."
      no_password

  entrypoint_and_snapshot := new_valid
  entrypoint_and_snapshot["containers"]["app1"]["snapshot"] = "foo.snapshot"
  expect_format_error
      "Container app1 has both entrypoint and snapshot."
      entrypoint_and_snapshot

  no_entrypoint_or_snapshot := new_valid
  no_entrypoint_or_snapshot["containers"]["app1"].remove "entrypoint"
  no_entrypoint_or_snapshot["containers"]["app1"].remove "snapshot"
  expect_format_error
      "Unsupported container app1: $no_entrypoint_or_snapshot["containers"]["app1"]"
      no_entrypoint_or_snapshot

  bad_arguments := new_valid
  bad_arguments["containers"]["app1"]["arguments"] = 1
  expect_format_error
      "Entry arguments in container app1 is not a list: 1"
      bad_arguments

  bad_arguments_not_strings := new_valid
  bad_arguments_not_strings["containers"]["app1"]["arguments"] = [1]
  expect_format_error
      "Entry arguments in container app1 is not a list of strings: [1]"
      bad_arguments_not_strings

  git_url_no_ref := new_valid
  git_url_no_ref["containers"]["app2"].remove "branch"
  expect_format_error
      "In container app2, git entry requires a branch/tag: foo"
      git_url_no_ref

  git_url_no_relative_path := new_valid
  git_url_no_relative_path["containers"]["app2"]["entrypoint"] = "/abs"
  expect_format_error
      "In container app2, git entry requires a relative path: /abs"
      git_url_no_relative_path

  bad_trigger := new_valid
  bad_trigger["containers"]["app4"]["triggers"] = [{ "foobar": true }]
  expect_format_error
      "Unknown trigger in container app4: {foobar: true}"
      bad_trigger

  bad_trigger = new_valid
  bad_trigger["containers"]["app4"]["triggers"] = ["foobar"]
  expect_format_error
      "Unknown trigger in container app4: foobar"
      bad_trigger

  bad_trigger = new_valid
  bad_trigger["containers"]["app4"]["triggers"] = [{"boot": true}]
  expect_format_error
      "Unknown trigger in container app4: {boot: true}"
      bad_trigger

  duplicate_trigger := new_valid
  duplicate_trigger["containers"]["app4"]["triggers"] = [
    { "interval": "5s" },
    { "interval": "5s" },
  ]
  expect_format_error
      "Duplicate trigger 'interval' in container app4"
      duplicate_trigger

  bad_interval := new_valid
  bad_interval["containers"]["app4"]["triggers"] = [{ "interval": "foobar" }]
  expect_format_error
      "Entry interval in trigger in container app4 is not a valid duration: foobar"
      bad_interval
