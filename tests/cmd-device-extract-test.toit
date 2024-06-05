// Copyright (C) 2022 Toitware ApS.

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

    result := test-cli.run --json [
      "fleet", "add-device", "--output-format", "json",
    ]
    device-id := uuid.parse result["id"]

    // To create a tar file we need to have an uploaded pod.
    upload-pod
        --format="tar"
        --test-cli=test-cli
        --fleet-dir=fleet-dir
        --args=args

    tar-file := "$tmp-dir/foo.tar"
    test-cli.run [
      "device", "extract", "--format", "tar", "-o", tar-file,
    ]
    expect (file.is-file tar-file)

    device-config := TestDeviceConfig
        --device-id=device-id
        --format="tar"
        --path=tar-file

    test-device := test-cli.start-device
        --alias-id=device-id
        --hardware-id=device-id  // Not really used anyway.
        --device-config=device-config

    pos := test-device.wait-for "$device-id" --start-at=0
    test-device.wait-for-synchronized --start-at=pos
    // test-device.close
