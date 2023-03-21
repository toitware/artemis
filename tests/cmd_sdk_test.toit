// Copyright (C) 2023 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.shared.server_config show ServerConfig
import host.directory
import host.file
import expect show *
import .utils

main args:
  with_test_cli --args=args: | test_cli/TestCli _ |
    run_test test_cli

run_test test_cli/TestCli:
  test_start := Time.now

  backdoor := test_cli.artemis_backdoor
  backdoor.install_service_images []

  output := test_cli.run [ "sdk", "list" ]
  /*
┌─────────────┬─────────────────┐
│ SDK Version   Service Version │
├─────────────┼─────────────────┤
└─────────────┴─────────────────┘
  */
  expect_not (output.contains "0")

  SDK_V1 ::= "v2.0.0-alpha.46"
  SDK_V2 ::= "v2.0.0-alpha.47"
  SERVICE_V1 ::= "v0.0.1"
  SERVICE_V2 ::= "v0.0.2"

  IMAGE_V1_V1 ::= "foobar"
  IMAGE_V2_V1 ::= "toto"
  IMAGE_V2_V2 ::= "titi"

  IGNORED_CONTENT ::= "ignored".to_byte_array

  test_images := [
    {
      "sdk_version": SDK_V1,
      "service_version": SERVICE_V1,
      "image": IMAGE_V1_V1,
      "content": IGNORED_CONTENT,
    },
    {
      "sdk_version": SDK_V2,
      "service_version": SERVICE_V1,
      "image": IMAGE_V2_V1,
      "content": IGNORED_CONTENT,
    },
    {
      "sdk_version": SDK_V2,
      "service_version": SERVICE_V2,
      "image": IMAGE_V2_V2,
      "content": IGNORED_CONTENT,
    },
  ]
  backdoor.install_service_images test_images

  output = test_cli.run [ "sdk", "list" ]
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
  found_v1_v1 := false
  found_v2_v1 := false
  found_v2_v2 := false
  lines.do: | line/string |
    if line.contains SDK_V1 and line.contains SERVICE_V1:
      found_v1_v1 = true
    if line.contains SDK_V2 and line.contains SERVICE_V1:
      found_v2_v1 = true
    if line.contains SDK_V2 and line.contains SERVICE_V2:
      found_v2_v2 = true
  expect found_v1_v1
  expect found_v2_v1
  expect found_v2_v2

  // Test filtering.
  output = test_cli.run [ "sdk", "list", "--sdk-version", SDK_V2 ]
  /*
  ┌─────────────────┬─────────────────┐
  │ SDK Version       Service Version │
  ├─────────────────┼─────────────────┤
  │ v2.0.0-alpha.47   v0.0.1          │
  │ v2.0.0-alpha.47   v0.0.2          │
  └─────────────────┴─────────────────┘
  */
  lines = output.split "\n"
  found_v1_v1 = false
  found_v2_v1 = false
  found_v2_v2 = false
  lines.do: | line/string |
    if line.contains SDK_V1 and line.contains SERVICE_V1:
      found_v1_v1 = true
    if line.contains SDK_V2 and line.contains SERVICE_V1:
      found_v2_v1 = true
    if line.contains SDK_V2 and line.contains SERVICE_V2:
      found_v2_v2 = true
  expect_not found_v1_v1
  expect found_v2_v1
  expect found_v2_v2

  // Same for service version.
  output = test_cli.run [ "sdk", "list", "--service-version", SERVICE_V1 ]
  /*
  ┌─────────────────┬─────────────────┐
  │ SDK Version       Service Version │
  ├─────────────────┼─────────────────┤
  │ v2.0.0-alpha.46   v0.0.1          │
  │ v2.0.0-alpha.47   v0.0.1          │
  └─────────────────┴─────────────────┘
  */
  lines = output.split "\n"
  found_v1_v1 = false
  found_v2_v1 = false
  found_v2_v2 = false
  lines.do: | line/string |
    if line.contains SDK_V1 and line.contains SERVICE_V1:
      found_v1_v1 = true
    if line.contains SDK_V2 and line.contains SERVICE_V1:
      found_v2_v1 = true
    if line.contains SDK_V2 and line.contains SERVICE_V2:
      found_v2_v2 = true
  expect found_v1_v1
  expect found_v2_v1
  expect_not found_v2_v2

  // Test sdk and service version.
  output = test_cli.run [ "sdk", "list", "--sdk-version", SDK_V2, "--service-version", SERVICE_V1 ]
  /*
  ┌─────────────────┬─────────────────┐
  │ SDK Version       Service Version │
  ├─────────────────┼─────────────────┤
  │ v2.0.0-alpha.47   v0.0.1          │
  └─────────────────┴─────────────────┘
  */
  lines = output.split "\n"
  found_v1_v1 = false
  found_v2_v1 = false
  found_v2_v2 = false
  lines.do: | line/string |
    if line.contains SDK_V1 and line.contains SERVICE_V1:
      found_v1_v1 = true
    if line.contains SDK_V2 and line.contains SERVICE_V1:
      found_v2_v1 = true
    if line.contains SDK_V2 and line.contains SERVICE_V2:
      found_v2_v2 = true
  expect_not found_v1_v1
  expect found_v2_v1
  expect_not found_v2_v2
