// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import host.file
import expect show *
import system
import uuid show Uuid
import .cli-device-extract show TestDeviceConfig
import .utils

main args:
  // We can't create host-devices on Windows.
  if system.platform == system.PLATFORM-WINDOWS: return

  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet --args=args

run-test fleet/TestFleet --args/List:
  with-tmp-directory: | tmp-dir |
    result := fleet.tester.run --json [
      "fleet", "add-device"
    ]
    device-id := Uuid.parse result["id"]

    // To create a tar file we need to have an uploaded pod.
    fleet.upload-pod "extract-pod" --format="tar"

    tar-file := "$tmp-dir/foo.tar"
    fleet.run [
      "device", "extract", "--format", "tar", "-o", tar-file,
    ]
    expect (file.is-file tar-file)

    device-config := TestDeviceConfig
        --device-id=device-id
        --format="tar"
        --path=tar-file

    test-device := fleet.tester.create-device
        --alias-id=device-id
        --hardware-id=device-id  // Not really used anyway.
        --device-config=device-config
    test-device.start

    pos := test-device.wait-for "$device-id" --start-at=0
    test-device.wait-for-synchronized --start-at=pos
    test-device.close
