// Copyright (C) 2023 Toitware ApS.

import host.file
import host.os
import expect show *
import .utils

main args:
  with_test_cli --args=args: | test_cli/TestCli |
    run_test test_cli

run_test test_cli/TestCli:
  with_tmp_directory: | fleet_tmp_dir |
    test_cli.run [
      "fleet",
      "--fleet-root", fleet_tmp_dir,
      "init",
      "--organization-id", "$TEST_ORGANIZATION_UUID",
    ]

    expect (file.is_file "$fleet_tmp_dir/fleet.json")
    expect (file.is_file "$fleet_tmp_dir/devices.json")
    expect (file.is_file "$fleet_tmp_dir/my-pod.json")

  with_tmp_directory: | fleet_tmp_dir |
    os.env["ARTEMIS_FLEET_ROOT"] = fleet_tmp_dir
    test_cli.run [
      "fleet",
      "init",
      "--organization-id", "$TEST_ORGANIZATION_UUID",
    ]

    expect (file.is_file "$fleet_tmp_dir/fleet.json")
    expect (file.is_file "$fleet_tmp_dir/devices.json")
    expect (file.is_file "$fleet_tmp_dir/my-pod.json")
