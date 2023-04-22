// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.shared.server_config show ServerConfig
import encoding.json
import host.directory
import host.file
import expect show *
import .utils

main args:
  with_test_cli --args=args: | test_cli/TestCli |
    run_test test_cli

run_test test_cli/TestCli:
  test_cli.run [
    "auth", "login",
    "--email", TEST_EXAMPLE_COM_EMAIL,
    "--password", TEST_EXAMPLE_COM_PASSWORD,
  ]

  test_cli.run [
    "auth", "login",
    "--broker",
    "--email", TEST_EXAMPLE_COM_EMAIL,
    "--password", TEST_EXAMPLE_COM_PASSWORD,
  ]

  with_tmp_directory: | fleet_tmp_dir |
    test_cli.run [
      "fleet",
      "--fleet-root", fleet_tmp_dir,
      "init",
      "--organization-id", TEST_ORGANIZATION_UUID,
    ]

    expect (file.is_file "$fleet_tmp_dir/fleet.json")
    expect (file.is_file "$fleet_tmp_dir/devices.json")
    expect (file.is_file "$fleet_tmp_dir/specification.json")

    // We are not allowed to
    already_initialized_message := test_cli.run --expect_exit_1 [
      "fleet",
      "--fleet-root", fleet_tmp_dir,
      "init",
      "--organization-id", TEST_ORGANIZATION_UUID,
    ]
    expect (already_initialized_message.contains "already contains a fleet.json file")

  with_tmp_directory: | fleet_tmp_dir |
    bad_org_id_message := test_cli.run --expect_exit_1 [
      "fleet",
      "--fleet-root", fleet_tmp_dir,
      "init",
      "--organization-id", NON_EXISTENT_UUID,
    ]
    expect (bad_org_id_message.contains "does not exist or")
