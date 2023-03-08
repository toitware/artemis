// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS BROKER

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.service.device show Device
import artemis.shared.server_config show ServerConfig
import host.directory
import host.file
import expect show *
import .utils

main args:
  with_test_cli --args=args: | test_cli/TestCli _ |
    run_test test_cli

run_test test_cli/TestCli:
  with_tmp_directory: | tmp_dir |
    test_cli.run [
      "auth", "artemis", "login",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    test_cli.run [
      "auth", "broker", "login",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    count := 3
    test_cli.run [
      "fleet",
      "create-identities",
      "--organization-id", TEST_ORGANIZATION_UUID,
      "--output-directory", tmp_dir,
      "$count",
    ]
    check_and_remove_identity_files tmp_dir count

    // Test an error when the organization id isn't set.
    test_cli.run --expect_exit_1 [
      "fleet",
      "create-identities",
      "--output-directory", tmp_dir,
      "1",
    ]
    check_and_remove_identity_files tmp_dir 0

    test_cli.run [
      "org", "default", TEST_ORGANIZATION_UUID,
    ]

    test_cli.run [
      "fleet",
      "create-identities",
      "--output-directory", tmp_dir,
      "1",
    ]
    check_and_remove_identity_files tmp_dir 1

check_and_remove_identity_files tmp_dir count:
  stream := directory.DirectoryStream tmp_dir
  count.repeat:
    identity_file := stream.next
    expect (identity_file.ends_with "identity")
    file.delete "$tmp_dir/$identity_file"
  expect_null stream.next
