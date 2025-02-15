// Copyright (C) 2024 Toitware ApS.

import artemis.cli.fleet as fleet-lib
import expect show *
import encoding.json
import host.file
import .utils

DEVICE-COUNT ::= 3

main args:
  with-fleet --count=DEVICE-COUNT --args=args: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  URL1 ::= "http://example.com:1234/recover.json"
  URL2 ::= "https://example.com:1234/recover.json"

  fleet.run-gold "010-show"
      "An empty list of recovery servers"
      ["fleet", "recovery", "list"]

  fleet.run-gold "020-add"
      "Add a recovery server"
      ["fleet", "recovery", "add", URL1]

  fleet.run ["fleet", "recovery", "add", URL2]

  fleet.run-gold "040-show"
      "List the recovery servers"
      ["fleet", "recovery", "list"]

  recovery-path := "$fleet.tester.tmp-dir/recovery.json"
  fleet.tester.run-gold "050-export"
      "Export the recovery information"
      ["fleet", "recovery", "export", "-o", recovery-path]

  // Just make sure that the file is there and is a valid JSON file with
  // some entries.
  exported := json.decode (file.read-contents recovery-path)
  expect (exported is Map)
  expect (exported.size > 0)

  fleet.run ["fleet", "recovery", "remove", URL1]

  recovery-servers := fleet.run --json ["fleet", "recovery", "list"]

  expect-list-equals [URL2] recovery-servers

  fleet.run --expect-exit-1 ["fleet", "recovery", "remove", URL1]
  fleet.run ["fleet", "recovery", "remove", "--force", URL1]

  recovery-servers = fleet.run --json ["fleet", "recovery", "list"]
  expect-list-equals [URL2] recovery-servers

  fleet.run ["fleet", "recovery", "remove", "--all"]
  recovery-servers = fleet.run --json ["fleet", "recovery", "list"]

  expect-list-equals [] recovery-servers
