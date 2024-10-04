// Copyright (C) 2024 Toitware ApS.

import .utils
import artemis.service.synchronize show SynchronizeJob
import expect show *

main args:
  with-tester --args=args: | tester/Tester |
    tester.login

    device := tester.create-device as TestDevicePipe
    device.start

    device.wait-until-connected

    expect device.has-backdoor
    expect-equals device.id device.backdoor.device-id

    device.backdoor.set-storage --ram "test-key" "test-value"
    expect-equals "test-value" (device.backdoor.get-storage --ram "test-key")

    device.backdoor.set-storage --flash "test-key" "test-value-flash"
    expect-equals "test-value-flash" (device.backdoor.get-storage --flash "test-key")
