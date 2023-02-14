// Copyright (C) 2022 Toitware ApS.

// TEST_FLAGS: ARTEMIS BROKER

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.service.device show Device
import artemis.shared.server_config show ServerConfig
import host.directory
import host.file
import uuid
import expect show *
import .utils

main args:
  with_test_cli
      --artemis_type=server_type_from_args args
      --broker_type=broker_type_from_args args
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
      "auth", "broker", "login",
      "--email", TEST_EXAMPLE_COM_EMAIL,
      "--password", TEST_EXAMPLE_COM_PASSWORD,
    ]

    test_cli.run [
      "device",
      "provision",
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
      "device",
      "provision",
      "-o", id_file,
    ]

    test_cli.run [
      "org", "default", TEST_ORGANIZATION_UUID,
    ]

    test_cli.run [
      "device",
      "provision",
      "-o", id_file,
    ]
    expect (file.is_file id_file)

    // Test with a given id.
    test_id := (uuid.uuid5 "provision-test" "$Time.now $random").stringify
    test_cli.run [
      "device",
      "provision",
      "--output-directory", tmp_dir,
      "--device_id", test_id,
    ]
    expect (file.is_file "$tmp_dir/$(test_id).identity")
