// Copyright (C) 2024 Toitware ApS.

import host.file
import expect show *
import system
import .utils

main args:
  // We can't create host-devices on Windows.
  if system.platform == system.PLATFORM-WINDOWS: return

  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  fleet.upload-pod "pod" --format="tar"
  device := fleet.create-host-device "dev1" --start

  hello-path := "$fleet.tester.tmp-dir/hello.toit"
  file.write-content --path=hello-path """
    main:
      print "Hello world"
    """
  fleet.run ["device", "-d", "$device.id", "container", "install", "hello", hello-path]
  device.wait-for "Hello world"

  fleet.run ["device", "-d", "$device.id", "container", "uninstall", "hello"]
  device.wait-for "[artemis.containers] INFO: uninstall {name: hello"

  device.wait-for "[artemis.containers] INFO: image uninstalled"
  device.wait-for "[artemis.synchronize] INFO: synchronized state to broker"

  device.clear-output
  // Wait for 2 synchrizations, and then check that there aren't any "synchronized state to broker"
  // anymore.
  device.wait-for-synchronized
  device.wait-for-synchronized
  expect-not (device.output.contains "synchronized state to broker")

  // Roll-out the same pod again.
  device.clear-output
  fleet.run ["fleet", "roll-out"]

  // Since we added and then removed a container, we should already have a state that is correct.
  // Wait for 2 synchronizations, and then check that we didn't try to "update".
  device.wait-for-synchronized
  device.wait-for-synchronized
  expect-not (device.output.contains "updating")
