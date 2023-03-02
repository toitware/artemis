// Copyright (C) 2023 Toitware ApS. All rights reserved.

import expect show *

import artemis.cli.device_specification show DeviceSpecification DeviceSpecificationException

parse str/string -> Duration:
  return DeviceSpecification.parse_max_offline_ str

expect_format_error str/string json/Map:
  exception := catch: DeviceSpecification.from_json json --path="ignored"
  expect exception is DeviceSpecificationException
  expect_equals str exception.message
  expect_equals str "$exception"

VALID_SPECIFICATION ::= {
  "version": 1,
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
    }
  }
}

new_valid -> Map:
  return deep_copy_ VALID_SPECIFICATION

deep_copy_ o/any -> any:
  if o is Map:
    return o.map: | _ value | deep_copy_ value
  if o is List:
    return o.map: deep_copy_ it
  return o

main:
  no_version := new_valid
  no_version.remove "version"
  expect_format_error
      "Missing version in device specification."
      no_version

  no_sdk_version := new_valid
  no_sdk_version.remove "sdk-version"
  expect_format_error
      "Missing sdk-version in device specification."
      no_sdk_version

  no_artemis_version := new_valid
  no_artemis_version.remove "artemis-version"
  expect_format_error
      "Missing artemis-version in device specification."
      no_artemis_version

  no_max_offline := new_valid
  no_max_offline.remove "max-offline"
  expect_format_error
      "Missing max-offline in device specification."
      no_max_offline

  no_connections := new_valid
  no_connections.remove "connections"
  expect_format_error
      "Missing connections in device specification."
      no_connections

  no_containers := new_valid
  no_containers.remove "containers"
  expect_format_error
      "Missing containers in device specification."
      no_containers

  both_apps_and_containers := new_valid
  both_apps_and_containers["apps"] = both_apps_and_containers["containers"]
  expect_format_error
      "Both 'apps' and 'containers' are present in device specification."
      both_apps_and_containers

  invalid_version := new_valid
  invalid_version["version"] = 2
  expect_format_error
      "Unsupported device specification version 2"
      invalid_version

  invalid_containers := new_valid
  invalid_containers["containers"] = 1
  expect_format_error
      "Entry containers in device specification is not a map: 1"
      invalid_containers

  invalid_container := new_valid
  invalid_container["containers"]["app1"] = 1
  expect_format_error
      "Container app1 in device specification is not a map: 1"
      invalid_container

  invalid_connections := new_valid
  invalid_connections["connections"] = 1
  expect_format_error
      "Entry connections in device specification is not a list: 1"
      invalid_connections

  invalid_connection := new_valid
  invalid_connection["connections"][0] = 1
  expect_format_error
      "Connection in device specification is not a map: 1"
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
