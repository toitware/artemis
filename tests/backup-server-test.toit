// Copyright (C) 2024 Toitware ApS.

import .utils
import artemis.service.synchronize show SynchronizeJob
import expect show *

main args:
  with-test-cli --args=args: | test-cli/TestCli |
    test-cli.login

    device := test-cli.create-device as TestDevicePipe
    device.start

    device.wait-until-connected

    expect device.has-backdoor
    expect-equals "bar" device.backdoor.foo
