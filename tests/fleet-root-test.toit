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
  // shape (no $schema, no scope inside server entries, organization at
  // the top level). We initialize a new fleet, rewrite the file in the
  // legacy shape, then exercise a command that has to parse it.
  with-tmp-directory: | fleet-tmp-dir |
    tester.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "init",
      "--organization-id", "$TEST-ORGANIZATION-UUID",
    ]
    fleet-path := "$fleet-tmp-dir/fleet.json"
    new-format := json.decode (file.read-contents fleet-path)
    legacy := new-format.copy
    legacy.remove "\$schema"
    broker-name := legacy["broker"]
    legacy-servers := (legacy["servers"] as Map).copy
    legacy-servers.do: | name encoded-server |
      cleaned := (encoded-server as Map).copy
      if name == broker-name:
        legacy["organization"] = cleaned["scope"]
      cleaned.remove "scope"
      legacy-servers[name] = cleaned
    legacy["servers"] = legacy-servers
    file.write-contents --path=fleet-path (json.encode legacy)
    tester.run [
      "fleet",
      "--fleet-root", fleet-tmp-dir,
      "group",
      "list",
    ]
