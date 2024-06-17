// Copyright (C) 2024 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli.utils show read-json
import host.file
import expect show *
import system
import uuid
import .cli-device-extract show TestDeviceConfig
import .utils

main args:
  // We can't create host-devices on Windows.
  if system.platform == system.PLATFORM-WINDOWS: return

  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet --args=args

run-test fleet/TestFleet --args/List:
  fleet-dir := fleet.fleet-dir
  with-tmp-directory: | tmp-dir |
    devices-before := read-json "$fleet-dir/devices.json"
    fleet.run [
      "fleet", "add-device",
    ]
    devices-after := read-json "$fleet-dir/devices.json"
    expect-equals (devices-before.size + 1) devices-after.size

    // To create a tar file we need to have an uploaded pod.
    fleet.upload-pod "add-device-pod" --format="tar"

    // When providing an output file one has to give the format.
    fleet.run --expect-exit-1 [
      "fleet", "add-device", "-o", "$tmp-dir/foo",
    ]

    tar-file := "$tmp-dir/foo.tar"
    fleet.run [
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

    test-device := fleet.test-cli.create-device
        --alias-id=tar-device-id
        --hardware-id=tar-device-id  // Not really used anyway.
        --device-config=device-config
    test-device.start

    test-device.wait-for "$tar-device-id"
    test-device.wait-for-synchronized
    test-device.close

    // Get the device info as json.
    result := fleet.run --json [
      "fleet", "add-device", "--format", "tar", "-o", tar-file, "--output-format", "json"
    ]

    new-id := uuid.parse result["id"]
    device-config = TestDeviceConfig
        --device-id=new-id
        --format="tar"
        --path=tar-file

    test-device = fleet.test-cli.create-device
        --alias-id=new-id
        --hardware-id=new-id  // Not really used anyway.
        --device-config=device-config
    test-device.start

    test-device.wait-for "$new-id"
    test-device.wait-for-synchronized
    test-device.close
