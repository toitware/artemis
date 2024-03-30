// Copyright (C) 2023 Toitware ApS. All rights reserved.

import expect show *

import artemis.cli.pod-specification
  show
    PodSpecification
    PodSpecificationException
    INITIAL-POD-SPECIFICATION
    EXAMPLE-POD-SPECIFICATION

import .utils

main:
  test-examples
  test-custom-envelope
  test-errors

test-examples:
  PodSpecification.from-json INITIAL-POD-SPECIFICATION --path="ignored"
  PodSpecification.from-json EXAMPLE-POD-SPECIFICATION --path="ignored"

expect-format-error str/string json/Map:
  exception := catch: PodSpecification.from-json json --path="ignored"
  expect exception is PodSpecificationException
  expect-equals str exception.message
  expect-equals str "$exception"

VALID-SPECIFICATION ::= {
  "\$schema": "https://toit.io/schemas/artemis/pod-specification/v1.json",
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

new-valid -> Map:
  return deep-copy_ VALID-SPECIFICATION

test-custom-envelope:
  custom-envelope := new-valid
  custom-envelope["envelope"] = "envelope-path"
  custom-envelope.remove "sdk-version"
  pod := PodSpecification.from-json custom-envelope --path="ignored"
  expect-equals "envelope-path" pod.envelope

  version-and-envelope := new-valid
  version-and-envelope["envelope"] = "envelope-path"
  pod = PodSpecification.from-json version-and-envelope --path="ignored"
  expect-equals "envelope-path" pod.envelope
  expect-equals "1.0.0" pod.sdk-version

test-errors:
  no-schema := new-valid
  no-schema.remove "\$schema"
  expect-format-error
      "Missing \$schema in pod specification."
      no-schema

  // We do allow a "version=1" instead of the $schema.
  version-schema := new-valid
  version-schema.remove "\$schema"
  version-schema["version"] = 1
  // Parsing should not throw.
  PodSpecification.from-json version-schema --path="ignored"

  version-schema["version"] = 2
  expect-format-error
      "Unsupported pod specification version 2"
      version-schema

  no-name := new-valid
  no-name.remove "name"
  expect-format-error
      "Missing name in pod specification."
      no-name

  no-sdk-version := new-valid
  no-sdk-version.remove "sdk-version"
  expect-format-error
      "Neither 'sdk-version' nor 'envelope' are present in pod specification."
      no-sdk-version

  bad-sdk-version := new-valid
  bad-sdk-version["sdk-version"] = 2
  expect-format-error
      "Entry sdk-version in pod specification is not a string: 2"
      bad-sdk-version

  bad-sdk-version2 := new-valid
  bad-sdk-version2["sdk-version"] = "v1.0.0.5"
  expect-format-error
      "Invalid sdk-version: v1.0.0.5"
      bad-sdk-version2

  no-artemis-version := new-valid
  no-artemis-version.remove "artemis-version"
  expect-format-error
      "Missing artemis-version in pod specification."
      no-artemis-version

  no-max-offline := new-valid
  no-max-offline.remove "max-offline"
  no-max-offline-spec := PodSpecification.from-json no-max-offline --path="ignored"
  expect-equals 0 no-max-offline-spec.max-offline-seconds

  no-connections := new-valid
  no-connections.remove "connections"
  expect-format-error
      "Missing connections in pod specification."
      no-connections

  no-containers := new-valid
  no-containers.remove "containers"
  // Should work without error.
  PodSpecification.from-json no-containers --path="ignored"

  [ null, "critical", "priority", "normal", 1, 2, 3, 5, 1000 ].do: | runlevel |
    runlevel-app4 := new-valid
    runlevel-app4["containers"]["app4"]["runlevel"] = runlevel
    // Should work without error.
    PodSpecification.from-json runlevel-app4 --path="ignored"

  both-apps-and-containers := new-valid
  both-apps-and-containers["apps"] = both-apps-and-containers["containers"]
  expect-format-error
      "Both 'apps' and 'containers' are present in pod specification."
      both-apps-and-containers

  invalid-schema := new-valid
  invalid-schema["\$schema"] = "bad schema"
  expect-format-error
      "Unsupported pod specification schema: bad schema"
      invalid-schema

  invalid-containers := new-valid
  invalid-containers["containers"] = 1
  expect-format-error
      "Entry containers in pod specification is not a map: 1"
      invalid-containers

  invalid-container := new-valid
  invalid-container["containers"]["app1"] = 1
  expect-format-error
      "Container app1 in pod specification is not a map: 1"
      invalid-container

  invalid-connections := new-valid
  invalid-connections["connections"] = 1
  expect-format-error
      "Entry connections in pod specification is not a list: 1"
      invalid-connections

  invalid-connection := new-valid
  invalid-connection["connections"][0] = 1
  expect-format-error
      "Connection in pod specification is not a map: 1"
      invalid-connection

  no-type := new-valid
  no-type["connections"][0].remove "type"
  expect-format-error
      "Missing type in connection."
      no-type

  invalid-type := new-valid
  invalid-type["connections"][0]["type"] = "invalid"
  expect-format-error
      "Unknown connection type: invalid"
      invalid-type

  no-ssid := new-valid
  no-ssid["connections"][0].remove "ssid"
  expect-format-error
      "Missing ssid in wifi connection."
      no-ssid

  no-password := new-valid
  no-password["connections"][0].remove "password"
  expect-format-error
      "Missing password in wifi connection."
      no-password

  entrypoint-and-snapshot := new-valid
  entrypoint-and-snapshot["containers"]["app1"]["snapshot"] = "foo.snapshot"
  expect-format-error
      "Container app1 has both entrypoint and snapshot."
      entrypoint-and-snapshot

  no-entrypoint-or-snapshot := new-valid
  no-entrypoint-or-snapshot["containers"]["app1"].remove "entrypoint"
  no-entrypoint-or-snapshot["containers"]["app1"].remove "snapshot"
  expect-format-error
      "Unsupported container app1: $no-entrypoint-or-snapshot["containers"]["app1"]"
      no-entrypoint-or-snapshot

  bad-arguments := new-valid
  bad-arguments["containers"]["app1"]["arguments"] = 1
  expect-format-error
      "Entry arguments in container app1 is not a list: 1"
      bad-arguments

  bad-arguments-not-strings := new-valid
  bad-arguments-not-strings["containers"]["app1"]["arguments"] = [1]
  expect-format-error
      "Entry arguments in container app1 is not a list of strings: [1]"
      bad-arguments-not-strings

  git-url-no-ref := new-valid
  git-url-no-ref["containers"]["app2"].remove "branch"
  expect-format-error
      "In container app2, git entry requires a branch/tag: foo"
      git-url-no-ref

  git-url-no-relative-path := new-valid
  git-url-no-relative-path["containers"]["app2"]["entrypoint"] = "/abs"
  expect-format-error
      "In container app2, git entry requires a relative path: /abs"
      git-url-no-relative-path

  bad-compile-flag := new-valid
  bad-compile-flag["containers"]["app2"]["compile-flags"] = 1
  expect-format-error
      "Entry compile-flags in container app2 is not a list: 1"
      bad-compile-flag

  bad-compile-flag2 := new-valid
  bad-compile-flag2["containers"]["app2"]["compile-flags"] = [1]
  expect-format-error
      "Entry compile-flags in container app2 is not a list of strings: [1]"
      bad-compile-flag2

  bad-trigger := new-valid
  bad-trigger["containers"]["app4"]["triggers"] = [{ "foobar": true }]
  expect-format-error
      "Unknown trigger in container app4: {foobar: true}"
      bad-trigger

  bad-trigger = new-valid
  bad-trigger["containers"]["app4"]["triggers"] = ["foobar"]
  expect-format-error
      "Unknown trigger in container app4: foobar"
      bad-trigger

  bad-trigger = new-valid
  bad-trigger["containers"]["app4"]["triggers"] = [{"boot": true}]
  expect-format-error
      "Unknown trigger in container app4: {boot: true}"
      bad-trigger

  duplicate-trigger := new-valid
  duplicate-trigger["containers"]["app4"]["triggers"] = [
    { "interval": "5s" },
    { "interval": "5s" },
  ]
  expect-format-error
      "Duplicate trigger 'interval' in container app4"
      duplicate-trigger

  bad-interval := new-valid
  bad-interval["containers"]["app4"]["triggers"] = [{ "interval": "foobar" }]
  expect-format-error
      "Entry interval in trigger in container app4 is not a valid duration: foobar"
      bad-interval

  [ -100, -10, 0].do: | bad/int |
    bad-runlevel := new-valid
    bad-runlevel["containers"]["app4"]["runlevel"] = bad
    expect-format-error
        "Entry runlevel in container app4 must be positive"
        bad-runlevel

  [ "", "safe", "stop", "criticalz" ].do: | bad/string |
    bad-runlevel := new-valid
    bad-runlevel["containers"]["app4"]["runlevel"] = bad
    expect-format-error
        "Unknown runlevel in container app4: $bad"
        bad-runlevel

  [ 3.5, true ].do: | bad |
    bad-runlevel := new-valid
    bad-runlevel["containers"]["app4"]["runlevel"] = bad
    expect-format-error
        "Entry runlevel in container app4 is not an int or a string: $bad"
        bad-runlevel
