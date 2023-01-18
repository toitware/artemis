// Copyright (C) 2022 Toitware ApS.

// TEST_FLAGS: --supabase-server --http-server

import .brokers

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
  if args.is_empty: args = ["--http-server"]

  artemis_type/string := ?
  if args[0] == "--supabase-server":  artemis_type = "supabase"
  else if args[0] == "--http-server": artemis_type = "http"
  else: throw "Unknown artemis type: $args[0]"

  with_test_cli
      --artemis_type=artemis_type
      --broker_type="supabase"
      --no-start_device_artemis
      : | test_cli/TestCli _ |
        run_test test_cli

run_test test_cli/TestCli:
  with_tmp_directory: | tmp_dir |
    test_cli.run [
      "auth", "artemis", "login",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    test_cli.run [
      "provision",
      "create-identity",
      "--organization-id", TEST_ORGANIZATION_UUID,
      "--output-directory", tmp_dir,
    ]
    files := directory.DirectoryStream tmp_dir
    identity_file := files.next
    expect (identity_file.ends_with "identity")
    expect_null files.next

    id_file := "$tmp_dir/id"

    // Test an error when the organization id isn't set.
    test_cli.run --expect_exit_1 [
      "provision",
      "create-identity",
      "-o", id_file,
    ]

    test_cli.run [
      "org", "default", TEST_ORGANIZATION_UUID,
    ]

    test_cli.run [
      "provision",
      "create-identity",
      "-o", id_file,
    ]
    expect (file.is_file id_file)
