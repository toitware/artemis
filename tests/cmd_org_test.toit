// Copyright (C) 2022 Toitware ApS.

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

main:
  with_test_cli
      --artemis_type="supabase"
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

    output := test_cli.run [ "org", "list" ]
    /*
    We might have orgs from earlier runs.
    The output should look something like:
    ┌──────────────────────────────────────┬───────────────────┐
    │ ID                                     Name              │
    ├──────────────────────────────────────┼───────────────────┤
    │ 4b6d9e35-cae9-44c0-8da0-6b0e485987e2   Test Organization │
    │ 6b2e1a1d-3a98-401e-93ac-0b062560e9ac   Testy             │
    │ 5f8ce858-f5d0-400b-a00f-97b4e4a78692   Testy             │
    └──────────────────────────────────────┴───────────────────┘
    */
    expect (output.contains "Test Organization")
    expect (output.contains "4b6d9e35-cae9-44c0-8da0-6b0e485987e2")
    original_lines := output.split "\n"

    create_output := test_cli.run [ "org", "create", "Testy" ]
    // Should be something like
    //   "Created organization 6b2e1a1d-3a98-401e-93ac-0b062560e9ac - Testy"
    expect (create_output.starts_with "Created organization")
    expect (create_output.contains "Testy")
    id := (create_output.split " ")[2]
    expect (id.size == 36)

    after_output := test_cli.run [ "org", "list" ]
    after_lines := after_output.split "\n"
    // Given that the original output already contained "Test Organization" which
    // has a longer name than "Testy", we know that the layout hasn't changed.
    // All lines should be the same, except the new one with our new organization.
    expect (after_lines.size == original_lines.size + 1)
    after_lines.do: | line |
      if line.contains id:
        expect (line.contains "Testy")
      else:
        expect (original_lines.contains line)
