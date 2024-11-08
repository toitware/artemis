// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import expect show *
import .utils

main args:
  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet.tester

run-test tester/Tester:
  test-start := Time.now

  backdoor := tester.artemis.backdoor
  backdoor.install-service-images []

  tester.login

  output := tester.run [ "sdk", "list" ]
  /*
┌─────────────┬─────────────────┐
│ SDK Version   Service Version │
├─────────────┼─────────────────┤
└─────────────┴─────────────────┘
  */
  expect-not (output.contains "0")

  SDK-V1 ::= "v2.0.0-alpha.46"
  SDK-V2 ::= "v2.0.0-alpha.47"
  SERVICE-V1 ::= "v0.0.1"
  SERVICE-V2 ::= "v0.0.2"

  IMAGE-V1-V1 ::= "foobar"
  IMAGE-V2-V1 ::= "toto"
  IMAGE-V2-V2 ::= "titi"

  IGNORED-CONTENTS ::= "ignored".to-byte-array

  test-images := [
    {
      "sdk_version": SDK-V1,
      "service_version": SERVICE-V1,
      "image": IMAGE-V1-V1,
      "content": IGNORED-CONTENTS,
    },
    {
      "sdk_version": SDK-V2,
      "service_version": SERVICE-V1,
      "image": IMAGE-V2-V1,
      "content": IGNORED-CONTENTS,
    },
    {
      "sdk_version": SDK-V2,
      "service_version": SERVICE-V2,
      "image": IMAGE-V2-V2,
      "content": IGNORED-CONTENTS,
    },
  ]
  backdoor.install-service-images test-images

  output = tester.run [ "sdk", "list" ]
  /*
  ┌─────────────────┬─────────────────┐
  │ SDK Version       Service Version │
  ├─────────────────┼─────────────────┤
  │ v2.0.0-alpha.46   v0.0.1          │
  │ v2.0.0-alpha.47   v0.0.1          │
  │ v2.0.0-alpha.47   v0.0.2          │
  └─────────────────┴─────────────────┘
  */
  lines := output.split "\n"
  found-v1-v1 := false
  found-v2-v1 := false
  found-v2-v2 := false
  lines.do: | line/string |
    if line.contains SDK-V1 and line.contains SERVICE-V1:
      found-v1-v1 = true
    if line.contains SDK-V2 and line.contains SERVICE-V1:
      found-v2-v1 = true
    if line.contains SDK-V2 and line.contains SERVICE-V2:
      found-v2-v2 = true
  expect found-v1-v1
  expect found-v2-v1
  expect found-v2-v2

  // Test filtering.
  output = tester.run [ "sdk", "list", "--sdk-version", SDK-V2 ]
  /*
  ┌─────────────────┬─────────────────┐
  │ SDK Version       Service Version │
  ├─────────────────┼─────────────────┤
  │ v2.0.0-alpha.47   v0.0.1          │
  │ v2.0.0-alpha.47   v0.0.2          │
  └─────────────────┴─────────────────┘
  */
  lines = output.split "\n"
  found-v1-v1 = false
  found-v2-v1 = false
  found-v2-v2 = false
  lines.do: | line/string |
    if line.contains SDK-V1 and line.contains SERVICE-V1:
      found-v1-v1 = true
    if line.contains SDK-V2 and line.contains SERVICE-V1:
      found-v2-v1 = true
    if line.contains SDK-V2 and line.contains SERVICE-V2:
      found-v2-v2 = true
  expect-not found-v1-v1
  expect found-v2-v1
  expect found-v2-v2

  // Same for service version.
  output = tester.run [ "sdk", "list", "--service-version", SERVICE-V1 ]
  /*
  ┌─────────────────┬─────────────────┐
  │ SDK Version       Service Version │
  ├─────────────────┼─────────────────┤
  │ v2.0.0-alpha.46   v0.0.1          │
  │ v2.0.0-alpha.47   v0.0.1          │
  └─────────────────┴─────────────────┘
  */
  lines = output.split "\n"
  found-v1-v1 = false
  found-v2-v1 = false
  found-v2-v2 = false
  lines.do: | line/string |
    if line.contains SDK-V1 and line.contains SERVICE-V1:
      found-v1-v1 = true
    if line.contains SDK-V2 and line.contains SERVICE-V1:
      found-v2-v1 = true
    if line.contains SDK-V2 and line.contains SERVICE-V2:
      found-v2-v2 = true
  expect found-v1-v1
  expect found-v2-v1
  expect-not found-v2-v2

  // Test sdk and service version.
  output = tester.run [ "sdk", "list", "--sdk-version", SDK-V2, "--service-version", SERVICE-V1 ]
  /*
  ┌─────────────────┬─────────────────┐
  │ SDK Version       Service Version │
  ├─────────────────┼─────────────────┤
  │ v2.0.0-alpha.47   v0.0.1          │
  └─────────────────┴─────────────────┘
  */
  lines = output.split "\n"
  found-v1-v1 = false
  found-v2-v1 = false
  found-v2-v2 = false
  lines.do: | line/string |
    if line.contains SDK-V1 and line.contains SERVICE-V1:
      found-v1-v1 = true
    if line.contains SDK-V2 and line.contains SERVICE-V1:
      found-v2-v1 = true
    if line.contains SDK-V2 and line.contains SERVICE-V2:
      found-v2-v2 = true
  expect-not found-v1-v1
  expect found-v2-v1
  expect-not found-v2-v2
