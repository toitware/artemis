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
  test_start := Time.now

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
  expect (output.contains TEST_ORGANIZATION_NAME)
  expect (output.contains TEST_ORGANIZATION_UUID)
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
  expect (after_lines.size == original_lines.size + 1)
  // Given that the original output already contained "Test Organization" which
  // has a longer name than "Testy", we know that the layout hasn't changed.
  // All lines should be the same, except the new one with our new organization.
  expect TEST_ORGANIZATION_NAME.size > "Testy".size
  after_lines.do: | line |
    if line.contains id:
      expect (line.contains "Testy")
    else:
      expect (original_lines.contains line)

  // Test 'org show'.
  show_output := test_cli.run [ "org", "show", "--org-id", id ]
  expect (show_output.contains "Testy")
  expect (show_output.contains id)
  // Find the 'Created' output.
  created_pos := show_output.index_of "Created: "
  expect (created_pos >= 0)
  line_end := show_output.index_of "\n" created_pos
  expect (line_end >= 0)
  created := show_output[created_pos + "Created: ".size..line_end]
  created_time := Time.from_string created
  // We trim the milliseconds when printing the "Created".
  // Give the test some slack.
  expect (created_time >= test_start - (Duration --s=2))
  expect (created_time <= Time.now)

  // Test 'org use' and 'org default'.
  // TODO(florian): test no-default and bad default organization.
  // Currently we can't do that, as the program exits with 'exit 1' in that
  // case and we wouldn't be able to stop that.

  use_output := test_cli.run [ "org", "use", id ]
  expect (use_output.contains "set to")
  expect (use_output.contains "Testy")

  default_output := test_cli.run [ "org", "default"]
  expect (default_output.contains "Name: Testy")
  expect (default_output.contains "ID: $id")

  default_id_only := test_cli.run [ "org", "default", "--id-only" ]
  expect (default_id_only.trim == id)

  // Once a default organization is set, we can use 'org show' without arguments.
  show_default_output := test_cli.run [ "org", "show" ]
  expect (show_default_output.contains "Testy")
  expect (show_default_output.contains id)

  // Test member functions.
  // members {add, list, remove, set-role}
  // roles "admin", "member"

  list_output := test_cli.run [ "org", "members", "list" ]
  expect (list_output.contains TEST_EXAMPLE_COM_UUID)
  expect (list_output.contains "admin")
  expect_not (list_output.contains DEMO_EXAMPLE_COM_UUID)

  test_cli.run [ "org", "members", "add", DEMO_EXAMPLE_COM_UUID ]
  list_output = test_cli.run [ "org", "members", "list" ]
  lines := list_output.split "\n"
  found_test_user := false
  found_demo_user := false
  lines.do: | line |
    if line.contains TEST_EXAMPLE_COM_EMAIL:
      found_test_user = true
      expect (line.contains "admin")
    if line.contains DEMO_EXAMPLE_COM_EMAIL:
      found_demo_user = true
      expect (line.contains "member")
      // By default 'list' also contains the name.
      expect (line.contains DEMO_EXAMPLE_COM_NAME)
  expect found_test_user
  expect found_demo_user

  // Test 'org members list --id-only'.
  list_output = test_cli.run [ "org", "members", "list", "--id-only" ]
  lines = list_output.split "\n"
  found_test_user = false
  found_demo_user = false
  lines.do: | line |
    if line.contains TEST_EXAMPLE_COM_UUID:
      found_test_user = true
      expect_not (line.contains "admin")
    if line.contains DEMO_EXAMPLE_COM_UUID:
      found_demo_user = true
      expect_not (line.contains "member")
      expect_not (line.contains DEMO_EXAMPLE_COM_NAME)
  expect found_test_user
  expect found_demo_user

  // Change the demo user's role.
  test_cli.run [ "org", "members", "set-role", DEMO_EXAMPLE_COM_UUID, "admin" ]
  list_output = test_cli.run [ "org", "members", "list" ]
  lines = list_output.split "\n"
  found_test_user = false
  found_demo_user = false
  lines.do: | line |
    if line.contains TEST_EXAMPLE_COM_EMAIL:
      found_test_user = true
      expect (line.contains "admin")
    if line.contains DEMO_EXAMPLE_COM_EMAIL:
      found_demo_user = true
      expect (line.contains "admin")
  expect found_test_user
  expect found_demo_user

  // Remove the demo user.
  test_cli.run [ "org", "members", "remove", DEMO_EXAMPLE_COM_UUID ]
  list_output = test_cli.run [ "org", "members", "list" ]
  expect_not (list_output.contains DEMO_EXAMPLE_COM_EMAIL)

  // TODO(florian): test that we can't remove ourself without '--force'.
  // Currently that's not possible as we would 'exit 1'.
