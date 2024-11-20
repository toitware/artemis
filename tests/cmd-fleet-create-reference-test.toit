// Copyright (C) 2024 Toitware ApS.

import encoding.json
import host.directory
import host.file
import expect show *
import uuid show Uuid
import .utils

main args:
  with-fleet --count=0 --args=args: | fleet/TestFleet |
    run-test fleet

run-test fleet/TestFleet:
  fleet.run-gold "110-list-groups"
      "List the groups "
      [
        "fleet", "group", "list",
      ]

  fleet.run-gold "120-list-pods"
      "List the pods "
      [
        "pod", "list",
      ]

  ref-file := "$fleet.tester.tmp-dir/fleet.ref"
  fleet.run-gold "200-create-ref"
      "Create a ref"
      [
        "fleet", "create-reference", "-o", ref-file
      ]

  fleet-json := json.decode (file.read-contents ref-file)
  // Check that we have a broker entry.
  broker-name := fleet-json["broker"]
  broker-entry := fleet-json["servers"][broker-name]

  // We can still use the ref file to list pods.
  fleet.run-gold "210-list-pods-ref"
      "List the pods using the ref"
      [
        "pod", "list", "--fleet", ref-file
      ]

  // However, we don't have access to the groups anymore.
  fleet.run-gold --expect-exit-1 "220-list-groups-ref"
      "Fail when trying to list the groups using the ref"
      [
        "fleet", "group", "list", "--fleet", ref-file
      ]

  // We can't use a fleet file as reference.
  fleet.run-gold --expect-exit-1 "300-full-fleet-as-ref"
      "Fail when trying to use the full fleet as reference"
      [
        "pod", "list", "--fleet", "$fleet.fleet-dir/fleet.json"
      ]

  fake-fleet-dir := "$fleet.tester.tmp-dir/fake-fleet"
  directory.mkdir fake-fleet-dir
  fake-fleet-file := "$fake-fleet-dir/fleet.json"
  file.write-contents --path=fake-fleet-file (file.read-contents ref-file)

  fleet.run-gold --expect-exit-1 "310-ref-as-fleet"
      "Fail when trying to use a ref as fleet"
      [
        "pod", "list", "--fleet", fake-fleet-dir
      ]
