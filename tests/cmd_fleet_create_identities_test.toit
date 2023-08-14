// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import encoding.json
import host.directory
import host.file
import expect show *
import uuid show Uuid
import .utils

main args:
  with-fleet --count=0 --args=args: | test-cli/TestCli _ fleet-dir/string |
    run-test test-cli fleet-dir

run-test test-cli/TestCli fleet-dir/string:
  with-tmp-directory: | tmp-dir |
    test-cli.run [
      "auth", "login",
      "--email", TEST-EXAMPLE-COM-EMAIL,
      "--password", TEST-EXAMPLE-COM-PASSWORD,
    ]

    test-cli.run [
      "auth", "login",
      "--broker",
      "--email", TEST-EXAMPLE-COM-EMAIL,
      "--password", TEST-EXAMPLE-COM-PASSWORD,
    ]

    count := 3
    test-cli.run [
      "fleet",
      "create-identities",
      "--output-directory", tmp-dir,
      "$count",
    ]
    check-and-remove-identity-files fleet-dir tmp-dir count

    id := random-uuid
    alias1 := "$random-uuid"
    alias2 := "$random-uuid"
    aliases := [alias1, alias2]
    test-cli.run [
      "fleet",
      "create-identity",
      "--output-directory", tmp-dir,
      "--name", "test-name",
      "--alias", (aliases.join ","),
      "$id",
    ]
    check-and-remove-identity-files fleet-dir tmp-dir
        --id=id
        --name="test-name"
        --aliases=aliases

    test-cli.run --expect-exit-1 --allow-exception [
      "fleet",
      "create-identity",
      "--output-directory", tmp-dir,
      "$id",
    ]

check-and-remove-identity-files fleet-dir tmp-dir
    --id/Uuid?=null
    --name/string?=null
    --aliases/List?=null:
  devices/Map := json.decode (file.read-content "$fleet-dir/devices.json")
  expect-equals 1 devices.size
  device := devices.values.first
  if id: expect-equals "$id" devices.keys.first
  if name: expect-equals name device["name"]
  if aliases: expect-equals aliases device["aliases"]

  expect (file.is-file "$tmp-dir/$(id).identity")
  check-and-remove-identity-files fleet-dir tmp-dir 1

check-and-remove-identity-files fleet-dir tmp-dir count:
  devices := json.decode (file.read-content "$fleet-dir/devices.json")
  expect-equals count devices.size
  stream := directory.DirectoryStream tmp-dir
  count.repeat:
    identity-file := stream.next
    expect (identity-file.ends-with "identity")
    without-extension := identity-file[..identity-file.size - 9]
    expect (devices.contains without-extension)
    file.delete "$tmp-dir/$identity-file"
  expect-null stream.next
  // Reset the devices.json.
  devices-stream := file.Stream.for-write "$fleet-dir/devices.json"
  devices-stream.write "{}"
  devices-stream.close
