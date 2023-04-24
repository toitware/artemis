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
  with_tmp_directory: | fleet_tmp_dir |
    with_tmp_directory: | tmp_dir |
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

      test_cli.run [
        "fleet",
        "--fleet-root", fleet_tmp_dir,
        "init",
        "--organization-id", TEST_ORGANIZATION_UUID,
      ]

      count := 3
      test_cli.run [
        "fleet",
        "--fleet-root", fleet_tmp_dir,
        "create-identities",
        "--output-directory", tmp_dir,
        "$count",
      ]
      check_and_remove_identity_files fleet_tmp_dir tmp_dir count

check_and_remove_identity_files fleet_dir tmp_dir count:
  devices := json.decode (file.read_content "$fleet_dir/devices.json")
  expect_equals count devices.size
  stream := directory.DirectoryStream tmp_dir
  count.repeat:
    identity_file := stream.next
    expect (identity_file.ends_with "identity")
    without_extension := identity_file[..identity_file.size - 9]
    expect (devices.contains without_extension)
    file.delete "$tmp_dir/$identity_file"
  expect_null stream.next
  // Reset the devices.json.
  devices_stream := file.Stream.for_write "$fleet_dir/devices.json"
  devices_stream.write "{}"
  devices_stream.close
