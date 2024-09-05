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
  recovery-path := "$fleet.tester.tmp-dir/recovery.json"
  fleet.tester.run-gold "010-export"
      "Export the recovery information"
      ["fleet", "recovery", "export", "-o", recovery-path]

  // Just make sure that the file is there and is a valid JSON file with
  // some entries.
  exported := json.decode (file.read-content recovery-path)
  expect (exported is Map)
  expect (exported.size > 0)
