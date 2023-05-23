// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import artemis.cli
import artemis.cli.cache
import artemis.cli.config
import artemis.cli.server_config as cli_server_config
import artemis.service
import artemis.shared.server_config show ServerConfig
import host.directory
import host.file
import expect show *
import uuid
import .utils

main args:
  with_test_cli --args=args: | test_cli/TestCli |
    run_test test_cli

run_test test_cli/TestCli:
  test_start := Time.now

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

  // We might have orgs from earlier runs.
  // We also always have the Test Organization.
  old_entries := test_cli.run --json ["org", "list"]
  old_ids := {}
  old_entries.do: | entry/Map |
    old_ids.add entry["id"]

  expect (old_entries.any: | entry/Map |
    entry["name"] == TEST_ORGANIZATION_NAME and entry["id"] == "$TEST_ORGANIZATION_UUID")

  trim_old_ids := : | output/string |
    lines := output.split "\n"
    lines.filter --in_place: | line/string |
      not old_ids.any: | old_id/string |
        line.contains old_id
    lines.join "\n"

  test_cli.run_gold "010-list"
      "Initial list of organizations should be empty"
      --ignore_spacing
      // After filtering the 'org list' output should be empty.
      --before_gold=trim_old_ids
      [ "org", "list" ]

  id/string? := null
  test_cli.run_gold "110-create"
      "Create a new organization 'Testy'"
      --ignore_spacing
      --before_gold=: | output/string |
        entries := test_cli.run --json ["org", "list"]
        entries.do: | entry/Map |
          if not old_ids.contains entry["id"]:
            id = entry["id"]
            test_cli.replacements[id] = pad_replacement_id "NEW-ORG-ID"
        trim_old_ids.call output
      [ "org", "create", "Testy" ]
  expect_not_null id

  test_cli.run_gold "120-after-create"
      "After creating 'Testy' the list should contain it"
      --ignore_spacing
      --before_gold=trim_old_ids
      [ "org", "list" ]

  org_info := test_cli.run --json ["org", "show", "--organization-id", id]
  expect_equals "Testy" org_info["name"]
  expect_equals id org_info["id"]
  created_at := org_info["created"]
  created_time := Time.from_string created_at
  expect (created_time >= test_start)
  expect (created_time <= Time.now)
  test_cli.replacements[created_at] = "CREATED-AT"

  test_cli.run_gold "200-org-show"
      "Show the newly created org"
      ["org", "show", "--organization-id", id]

  test_cli.run_gold "210-org-rename"
      "Update the name of the org"
      ["org", "update", id, "--name", "Testy2"]

  test_cli.run_gold "220-org-show-renamed"
      "Show the renamed org"
      ["org", "show", "--organization-id", id]

  expect_equals "Testy2" (test_cli.run --json ["org", "show", "--organization-id", id])["name"]

  // Rename it back.
  test_cli.run ["org", "update", id, "--name", "Testy"]

  // Test 'org use' and 'org default'.

  // The last created org is the default (since we didn't use --no-default).
  org_info = test_cli.run --json ["org", "default"]
  expect_equals "Testy" org_info["name"]
  expect_equals id org_info["id"]
  expect_equals id (test_cli.run --json ["org", "default", "--id-only"])

  test_cli.run_gold "310-default-org"
      "The default org should be the last created one"
      ["org", "default"]
  test_cli.run_gold "315-default-org-id-only"
      "Show the default-org with --id-only"
      ["org", "default", "--id-only"]

  // TODO(florian): this is unfortunate. We would prefer not to have a
  // stack trace. That would require changes to the CLI package.
  expect_throw "Invalid value for option 'organization-id': 'bad_id'. Expected a UUID.":
    test_cli.run --expect_exit_1 ["org", "default", "bad_id"]

  UNKNOWN_UUID ::= uuid.uuid5 "unknown" "unknown"
  bad_use_output := test_cli.run --expect_exit_1 ["org", "default", "$UNKNOWN_UUID"]
  expect (bad_use_output.contains "Organization not found")

  // The default org is still set to Testy.
  test_cli.run_gold "320-still-default-org"
      "The default org is still be Testy"
      ["org", "default"]

  // Creating a new org with --no-default does not change the default.
  id2/string? := null
  test_cli.run_gold "330-create-no-default"
      "Create a new org 'Testy2' with --no-default"
      --before_gold=: | output/string |
        entries := test_cli.run --json ["org", "list"]
        entries.do: | entry/Map |
          if not old_ids.contains entry["id"] and entry["id"] != id:
            id2 = entry["id"]
            test_cli.replacements[id2] = pad_replacement_id "ORG-ID2"
        trim_old_ids.call output
      ["org", "create", "Testy2", "--no-default"]

  expect_equals id (test_cli.run --json ["org", "default", "--id-only"])

  // Set the default org.
  test_cli.run_gold "340-set-default"
      "Set the default org to 'Testy2'"
      ["org", "default", id2]

  expect_equals id2 (test_cli.run --json ["org", "default", "--id-only"])

  // Another bad setting doesn't change the default.
  // TODO(florian): this is unfortunate. We would prefer not to have a
  // stack trace. That would require changes to the CLI package.
  expect_throw "Invalid value for option 'organization-id': 'bad_id'. Expected a UUID.":
    test_cli.run --expect_exit_1 [ "org", "default", "bad_id" ]

  expect_equals id2 (test_cli.run --json ["org", "default", "--id-only"])

  org_info2 := test_cli.run --json ["org", "show", "--organization-id", id2]
  expect_equals "Testy2" org_info2["name"]
  expect_equals id2 org_info2["id"]
  created_at2 := org_info2["created"]
  test_cli.replacements[created_at2] = "CREATED-AT2"

  // Once a default organization is set, we can use 'org show' without arguments.
  test_cli.run_gold "350-show-default"
      "Show the default org"
      ["org", "show"]

  // Test member functions.
  // members {add, list, remove, set-role}
  // roles "admin", "member"

  members := test_cli.run --json [ "org", "members", "list" ]
  expect_equals 1 members.size
  expect_equals "admin" members[0]["role"]
  expect_equals TEST_EXAMPLE_COM_NAME members[0]["name"]
  expect_equals TEST_EXAMPLE_COM_EMAIL members[0]["email"]
  expect_equals "$TEST_EXAMPLE_COM_UUID" members[0]["id"]

  test_cli.run_gold "400-org-members-list"
      "List the members of the org"
      [ "org", "members", "list" ]

  test_cli.run_gold "410-org-members-add"
      "Add a member to the org"
      [ "org", "members", "add", "$DEMO_EXAMPLE_COM_UUID" ]
  test_cli.run_gold "420-org-members-after-add"
      "List the members of the org after adding a member"
      [ "org", "members", "list" ]

  // Add self again.
  test_cli.run_gold "425-add-self-again"
      "Add self again"
      --expect_exit_1
      [ "org", "members", "add", "$TEST_EXAMPLE_COM_UUID" ]

  member_ids := test_cli.run --json [ "org", "members", "list", "--id-only" ]
  expect_equals 2 member_ids.size
  expect (member_ids.contains "$TEST_EXAMPLE_COM_UUID")
  expect (member_ids.contains "$DEMO_EXAMPLE_COM_UUID")

  test_cli.run_gold "430-org-members-list-id-only"
      "List the members of the org with --id-only"
      [ "org", "members", "list", "--id-only" ]

  // Change the demo user's role.
  test_cli.run_gold "440-org-set-role"
      "Change the role of a member of the org"
      [ "org", "members", "set-role", "$DEMO_EXAMPLE_COM_UUID", "admin" ]

  test_cli.run_gold "450-org-members-after-set-role"
      "List the members of the org after changing a member's role"
      [ "org", "members", "list" ]

  // Remove the demo user.
  test_cli.run_gold "460-remove-member"
      "Remove a member from the org"
      [ "org", "members", "remove", "$DEMO_EXAMPLE_COM_UUID" ]
  ids := test_cli.run --json [ "org", "members", "list", "--id-only" ]
  expect_equals 1 ids.size
  expect (ids.contains "$TEST_EXAMPLE_COM_UUID")

  // We can't remove ourselves without '--force'.
  test_cli.run_gold "470-remove-self"
      "Try to remove ourselves from the org without --force"
      --expect_exit_1
      [ "org", "members", "remove", "$TEST_EXAMPLE_COM_UUID" ]

  expect_equals 1 (test_cli.run --json [ "org", "members", "list", "--id-only" ]).size

  // Remove ourselves with '--force'.
  test_cli.run_gold "480-remove-self-force"
      "Remove ourselves from the org with --force"
      [ "org", "members", "remove", "--force", "$TEST_EXAMPLE_COM_UUID" ]

  test_cli.run_gold "490-org-members-after-remove"
      "List the members of the org after removing self"
      [ "org", "members", "list" ]
