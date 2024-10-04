// Copyright (C) 2022 Toitware ApS.

// ARTEMIS_TEST_FLAGS: ARTEMIS

import expect show *
import uuid show Uuid
import .utils

main args:
  with-tester --args=args: | tester/Tester |
    run-test tester

run-test tester/Tester:
  test-start := Time.now

  tester.login

  // We might have orgs from earlier runs.
  // We also always have the Test Organization.
  old-entries := tester.run --json ["org", "list"]
  old-ids := {}
  old-entries.do: | entry/Map |
    old-ids.add entry["id"]

  expect (old-entries.any: | entry/Map |
    entry["name"] == TEST-ORGANIZATION-NAME and entry["id"] == "$TEST-ORGANIZATION-UUID")

  trim-old-ids := : | output/string |
    lines := output.split "\n"
    lines.filter --in-place: | line/string |
      not old-ids.any: | old-id/string |
        line.contains old-id
    lines.join "\n"

  tester.run-gold "010-list"
      "Initial list of organizations should be empty"
      --ignore-spacing
      // After filtering the 'org list' output should be empty.
      --before-gold=trim-old-ids
      [ "org", "list" ]

  id/string? := null
  tester.run-gold "110-create"
      "Create a new organization 'Testy'"
      --ignore-spacing
      --before-gold=: | output/string |
        entries := tester.run --json ["org", "list"]
        entries.do: | entry/Map |
          if not old-ids.contains entry["id"]:
            id = entry["id"]
            tester.replacements[id] = pad-replacement-id "NEW-ORG-ID"
        trim-old-ids.call output
      [ "org", "add", "Testy" ]
  expect-not-null id

  tester.run-gold "120-after-create"
      "After creating 'Testy' the list should contain it"
      --ignore-spacing
      --before-gold=trim-old-ids
      [ "org", "list" ]

  org-info := tester.run --json ["org", "show", id]
  expect-equals "Testy" org-info["name"]
  expect-equals id org-info["id"]
  created-at := org-info["created"]
  created-time := Time.parse created-at
  expect (created-time >= test-start)
  expect (created-time <= Time.now)
  tester.replacements[created-at] = "CREATED-AT"

  tester.run-gold "200-org-show"
      "Show the newly created org"
      ["org", "show", id]

  tester.run-gold "210-org-rename"
      "Update the name of the org"
      ["org", "update", id, "--name", "Testy2"]

  tester.run-gold "220-org-show-renamed"
      "Show the renamed org"
      ["org", "show", id]

  expect-equals "Testy2" (tester.run --json ["org", "show", id])["name"]

  // Rename it back.
  tester.run ["org", "update", id, "--name", "Testy"]

  // Test 'org use' and 'org default'.

  // The last created org is the default (since we didn't use --no-default).
  org-info = tester.run --json ["org", "default"]
  expect-equals "Testy" org-info["name"]
  expect-equals id org-info["id"]
  expect-equals id (tester.run --json ["org", "default", "--id-only"])

  tester.run-gold "310-default-org"
      "The default org should be the last created one"
      ["org", "default"]
  tester.run-gold "315-default-org-id-only"
      "Show the default-org with --id-only"
      ["org", "default", "--id-only"]

  // TODO(florian): this is unfortunate. We would prefer not to have a
  // stack trace. That would require changes to the CLI package.
  expect-throw "Invalid value for option 'organization-id': 'bad_id'. Expected a UUID.":
    tester.run --expect-exit-1 ["org", "default", "bad_id"]

  UNKNOWN-UUID ::= Uuid.uuid5 "unknown" "unknown"
  bad-use-output := tester.run --expect-exit-1 ["org", "default", "$UNKNOWN-UUID"]
  expect (bad-use-output.contains "Organization not found")

  // The default org is still set to Testy.
  tester.run-gold "320-still-default-org"
      "The default org is still be Testy"
      ["org", "default"]

  // Creating a new org with --no-default does not change the default.
  id2/string? := null
  tester.run-gold "330-create-no-default"
      "Create a new org 'Testy2' with --no-default"
      --before-gold=: | output/string |
        entries := tester.run --json ["org", "list"]
        entries.do: | entry/Map |
          if not old-ids.contains entry["id"] and entry["id"] != id:
            id2 = entry["id"]
            tester.replacements[id2] = pad-replacement-id "ORG-ID2"
        trim-old-ids.call output
      ["org", "add", "Testy2", "--no-default"]

  expect-equals id (tester.run --json ["org", "default", "--id-only"])

  // Set the default org.
  tester.run-gold "340-set-default"
      "Set the default org to 'Testy2'"
      ["org", "default", id2]

  expect-equals id2 (tester.run --json ["org", "default", "--id-only"])

  // Another bad setting doesn't change the default.
  // TODO(florian): this is unfortunate. We would prefer not to have a
  // stack trace. That would require changes to the CLI package.
  expect-throw "Invalid value for option 'organization-id': 'bad_id'. Expected a UUID.":
    tester.run --expect-exit-1 [ "org", "default", "bad_id" ]

  expect-equals id2 (tester.run --json ["org", "default", "--id-only"])

  org-info2 := tester.run --json ["org", "show", id2]
  expect-equals "Testy2" org-info2["name"]
  expect-equals id2 org-info2["id"]
  created-at2 := org-info2["created"]
  tester.replacements[created-at2] = "CREATED-AT2"

  // Once a default organization is set, we can use 'org show' without arguments.
  tester.run-gold "350-show-default"
      "Show the default org"
      ["org", "show"]

  // Test member functions.
  // members {add, list, remove, set-role}
  // roles "admin", "member"

  members := tester.run --json [ "org", "members", "list" ]
  expect-equals 1 members.size
  expect-equals "admin" members[0]["role"]
  expect-equals TEST-EXAMPLE-COM-NAME members[0]["name"]
  expect-equals TEST-EXAMPLE-COM-EMAIL members[0]["email"]
  expect-equals "$TEST-EXAMPLE-COM-UUID" members[0]["id"]

  tester.run-gold "400-org-members-list"
      "List the members of the org"
      [ "org", "members", "list" ]

  tester.run-gold "410-org-members-add"
      "Add a member to the org"
      [ "org", "members", "add", "$DEMO-EXAMPLE-COM-UUID" ]
  tester.run-gold "420-org-members-after-add"
      "List the members of the org after adding a member"
      [ "org", "members", "list" ]

  // Add self again.
  tester.run-gold "425-add-self-again"
      "Add self again"
      --expect-exit-1
      [ "org", "members", "add", "$TEST-EXAMPLE-COM-UUID" ]

  member-ids := tester.run --json [ "org", "members", "list", "--id-only" ]
  expect-equals 2 member-ids.size
  expect (member-ids.contains "$TEST-EXAMPLE-COM-UUID")
  expect (member-ids.contains "$DEMO-EXAMPLE-COM-UUID")

  tester.run-gold "430-org-members-list-id-only"
      "List the members of the org with --id-only"
      [ "org", "members", "list", "--id-only" ]

  // Change the demo user's role.
  tester.run-gold "440-org-set-role"
      "Change the role of a member of the org"
      [ "org", "members", "set-role", "$DEMO-EXAMPLE-COM-UUID", "admin" ]

  tester.run-gold "450-org-members-after-set-role"
      "List the members of the org after changing a member's role"
      [ "org", "members", "list" ]

  // Remove the demo user.
  tester.run-gold "460-remove-member"
      "Remove a member from the org"
      [ "org", "members", "remove", "$DEMO-EXAMPLE-COM-UUID" ]
  ids := tester.run --json [ "org", "members", "list", "--id-only" ]
  expect-equals 1 ids.size
  expect (ids.contains "$TEST-EXAMPLE-COM-UUID")

  // We can't remove ourselves without '--force'.
  tester.run-gold "470-remove-self"
      "Try to remove ourselves from the org without --force"
      --expect-exit-1
      [ "org", "members", "remove", "$TEST-EXAMPLE-COM-UUID" ]

  expect-equals 1 (tester.run --json [ "org", "members", "list", "--id-only" ]).size

  // Remove ourselves with '--force'.
  tester.run-gold "480-remove-self-force"
      "Remove ourselves from the org with --force"
      [ "org", "members", "remove", "--force", "$TEST-EXAMPLE-COM-UUID" ]

  tester.run-gold "490-org-members-after-remove"
      "List the members of the org after removing self"
      [ "org", "members", "list" ]
