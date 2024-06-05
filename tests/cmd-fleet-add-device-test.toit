// Copyright (C) 2024 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli.utils show read-json write-json-to-file
import encoding.json
import encoding.ubjson
import encoding.base64
import host.directory
import host.file
import expect show *
import uuid
import .cli-device-extract show TestDeviceConfig upload-pod
import .utils

main args:
  with-fleet --count=0 --args=args: | test-cli/TestCli _ fleet-dir/string |
    run-test args test-cli fleet-dir

run-test args/List test-cli/TestCli fleet-dir/string:
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

    devices-before := read-json "$fleet-dir/devices.json"
    test-cli.run [
      "fleet", "add-device",
    ]
    devices-after := read-json "$fleet-dir/devices.json"
    expect-equals (devices-before.size + 1) devices-after.size

    // To create a tar file we need to have an uploaded pod.
    upload-pod
        --format="tar"
        --test-cli=test-cli
        --fleet-dir=fleet-dir
        --args=args

    // When providing an output file one has to give the format.
    test-cli.run --expect-exit-1 [
      "fleet", "add-device", "-o", "$tmp-dir/foo",
    ]

    tar-file := "$tmp-dir/foo.tar"
    test-cli.run [
      "fleet", "add-device", "--format", "tar", "-o", tar-file,
    ]
    expect (file.is-file tar-file)
    devices-with-tar := read-json "$fleet-dir/devices.json"
    tar-device-id/uuid.Uuid? := null
    devices-with-tar.do: | uuid-str/string _ |
      if devices-after.contains uuid-str: continue.do
      tar-device-id = uuid.parse uuid-str

    device-config := TestDeviceConfig
        --device-id=tar-device-id
        --format="tar"
        --path=tar-file

    test-device := test-cli.start-device
        --alias-id=tar-device-id
        --hardware-id=tar-device-id  // Not really used anyway.
        --device-config=device-config

    pos := test-device.wait-for "$tar-device-id" --start-at=0
    test-device.wait-for-synchronized --start-at=pos
    test-device.close

    // Get the device info as json.
    result := test-cli.run --json [
      "fleet", "add-device", "--format", "tar", "-o", tar-file, "--output-format", "json"
    ]

    new-id := uuid.parse result["id"]
    device-config = TestDeviceConfig
        --device-id=new-id
        --format="tar"
        --path=tar-file

    test-device = test-cli.start-device
        --alias-id=new-id
        --hardware-id=new-id  // Not really used anyway.
        --device-config=device-config

    pos = test-device.wait-for "$new-id" --start-at=0
    test-device.wait-for-synchronized --start-at=pos
    test-device.close
