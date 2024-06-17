// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import encoding.json
import encoding.ubjson
import encoding.base64
import host.directory
import host.file
import expect show *
import uuid show Uuid
import uuid
import .utils

main args:
  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  fleet-dir := fleet.fleet-dir
  with-tmp-directory: | tmp-dir |
    count := 3
    fleet.run [
      "fleet",
      "add-devices",
      "--output-directory", tmp-dir,
      "$count",
    ]
    check-and-remove-identity-files fleet-dir tmp-dir count

    // Test the json output.
    count = 3
    added-devices/Map := fleet.run --json [
      "fleet",
      "add-devices",
      "--output-directory", tmp-dir,
      "$count",
    ]
    expect-equals count added-devices.size
    added-devices.do: | uuid-string/string path/string |
      // Make sure the uuid-string is actually a uuid.
      uuid.parse uuid-string
      expect (file.is-file path)
    check-and-remove-identity-files fleet-dir tmp-dir count

    id := random-uuid
    alias1 := "$random-uuid"
    alias2 := "$random-uuid"
    aliases := [alias1, alias2]
    fleet.run [
      "fleet",
      "add-device",
      "--format", "identity",
      "--output", "$tmp-dir/$(id).identity",
      "--name", "test-name",
      "--alias", (aliases.join ","),
      "--id", "$id",
    ]
    test-extract-identity fleet tmp-dir
    check-and-remove-identity-files fleet-dir tmp-dir
        --id=id
        --name="test-name"
        --aliases=aliases

    // We can't create the same device twice.
    fleet.run --expect-exit-1 --allow-exception [
      "fleet",
      "add-device",
      "--format", "identity",
      "--output", "$tmp-dir/other.identity",
      "--id", "$id",
    ]

test-extract-identity fleet/TestFleet tmp-dir/string:
  devices/Map := json.decode (file.read-content "$fleet.fleet-dir/devices.json")
  expect-equals 1 devices.size
  id := devices.keys.first
  device-id-file := "$tmp-dir/device-$(id).identity"
  fleet.run [
    "device",
    "-d", "$id",
    "extract",
    "--format", "identity",
    "-o", device-id-file,
  ]
  check-identity-file device-id-file --id=id
  file.delete device-id-file

check-and-remove-identity-files fleet-dir/string tmp-dir/string
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

check-and-remove-identity-files fleet-dir/string tmp-dir/string count/int:
  devices := json.decode (file.read-content "$fleet-dir/devices.json")
  expect-equals count devices.size
  stream := directory.DirectoryStream tmp-dir
  count.repeat:
    identity-file := stream.next
    expect (identity-file.ends-with "identity")
    without-extension := identity-file[..identity-file.size - 9]
    expect (devices.contains without-extension)
    check-identity-file "$tmp-dir/$identity-file" --id=without-extension
    file.delete "$tmp-dir/$identity-file"
  expect-null stream.next
  // Reset the devices.json.
  devices-stream := file.Stream.for-write "$fleet-dir/devices.json"
  devices-stream.out.write "{}"
  devices-stream.close

check-identity-file identity-path/string --id/string:
  identity := ubjson.decode (base64.decode (file.read-content identity-path))
  expect-equals id identity["artemis.device"]["device_id"]
  expect-equals "$TEST-ORGANIZATION-UUID" identity["artemis.device"]["organization_id"]
  expect-not-null identity["artemis.device"]["hardware_id"]
  expect-not-null identity["artemis.broker"]
  expect-not-null identity["broker"]
