// Copyright (C) 2023 Toitware ApS.

import encoding.json
import host.file
import host.os
import expect show *
import .utils

main args:
  with-tester --args=args: | tester/Tester |
    run-test tester

run-test tester/Tester:
  tester.login

  with-tmp-directory: | fleet-tmp-dir |
    tester.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]

    expect (file.is-file "$fleet-tmp-dir/fleet.json")
    expect (file.is-file "$fleet-tmp-dir/devices.json")
    expect (file.is-file "$fleet-tmp-dir/my-pod.yaml")

  with-tmp-directory: | fleet-tmp-dir |
    os.env["ARTEMIS_FLEET_ROOT"] = fleet-tmp-dir
    tester.run [
      "fleet",
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]

    expect (file.is-file "$fleet-tmp-dir/fleet.json")
    expect (file.is-file "$fleet-tmp-dir/devices.json")
    expect (file.is-file "$fleet-tmp-dir/my-pod.yaml")

  // Verify that the reader still understands the legacy fleet.json
  // shape (no $schema, broker as a string, organization at top level).
  // We initialize a new fleet, rewrite the file in the legacy shape,
  // then exercise a command that has to parse it.
  with-tmp-directory: | fleet-tmp-dir |
    tester.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]
    fleet-path := "$fleet-tmp-dir/fleet.json"
    new-format := json.decode (file.read-contents fleet-path)
    broker-entry := new-format["broker"]
    legacy := new-format.copy
    legacy.remove "\$schema"
    legacy["broker"] = broker-entry["ref"]
    legacy["organization"] = broker-entry["scope"]
    file.write-contents --path=fleet-path (json.encode legacy)
    tester.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "group",
      "list",
    ]
