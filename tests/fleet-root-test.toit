// Copyright (C) 2023 Toitware ApS.

import host.file
import host.os
import expect show *
import .utils

main args:
  with-test-cli --args=args: | test-cli/TestCli |
    run-test test-cli

run-test test-cli/TestCli:
  test-cli.login

  with-tmp-directory: | fleet-tmp-dir |
    test-cli.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]

    expect (file.is-file "$fleet-tmp-dir/fleet.json")
    expect (file.is-file "$fleet-tmp-dir/devices.json")
    expect (file.is-file "$fleet-tmp-dir/my-pod.yaml")

  with-tmp-directory: | fleet-tmp-dir |
    os.env["ARTEMIS_FLEET_ROOT"] = fleet-tmp-dir
    test-cli.run [
      "fleet",
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]

    expect (file.is-file "$fleet-tmp-dir/fleet.json")
    expect (file.is-file "$fleet-tmp-dir/devices.json")
    expect (file.is-file "$fleet-tmp-dir/my-pod.yaml")
