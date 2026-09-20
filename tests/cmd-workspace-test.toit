// Copyright (C) 2026 Toit contributors. All rights reserved.

import artemis.cli as artemis-cli
import artemis.cli.directory-fleet-store show FLEET-STATE-SCHEMA
import artemis.cli.utils show read-json read-yaml write-json-to-file
import artemis.cli.workspace show Workspace WORKSPACE-SCHEMA
import cli
import encoding.json as json-encoding
import artemis.shared.json-diff show json-equals
import expect show *
import fs
import host
import host.file

import .utils show TestUi TestExit with-tmp-config-cli

main:
  host.with-tmp-directory: | tmp/string |
    with-tmp-config-cli: | cli/cli.Cli |
      workspace := Workspace.from-map --path=(fs.join tmp "artemis.yaml") {
        "\$schema": WORKSPACE-SCHEMA,
        "servers": {:},
        "backends": {"fleet": {"type": "file", "directory": "state/fleet"}},
      }
      workspace.write
      manifest := file.read-contents workspace.path

      // An empty local config proves initialization does not require an organization or login.
      result := run cli ["fleet", "init", "--fleet", tmp] --json
      metadata := read-yaml (fs.join tmp "state/fleet/fleet.yaml")
      expect-equals result["id"] metadata["id"]
      expect-equals FLEET-STATE-SCHEMA metadata["\$schema"]
      expect-json {:} (read-json (fs.join tmp "state/fleet/devices.json"))
      expect-not (file.is-file (fs.join tmp "fleet.json"))
      expect-equals manifest (file.read-contents workspace.path)

      message := run cli ["fleet", "init", "--fleet", tmp] --fail
      expect (message.contains "already exists")
      expect-json metadata (read-yaml (fs.join tmp "state/fleet/fleet.yaml"))

      groups := run cli ["fleet", "group", "list", "--fleet", workspace.path] --json
      expect-json [{"name": "default", "pod": "my-pod@latest"}] groups
      run cli ["fleet", "group", "add", "staging", "--pod", "app@latest", "--force", "--fleet", tmp]
      run cli ["fleet", "group", "update", "staging", "--name", "production", "--fleet", tmp]
      run cli ["fleet", "group", "update", "production", "--pod", "app@v1", "--force", "--fleet", tmp]
      groups = run cli ["fleet", "group", "list", "--fleet", tmp] --json
      expect-json [
        {"name": "default", "pod": "my-pod@latest"},
        {"name": "production", "pod": "app@v1"},
      ] groups

      // Renaming a populated group persists both the assignment and the inventory.
      device-id := "00000000-0000-0000-0000-000000000001"
      devices-path := fs.join tmp "state/fleet/devices.json"
      write-json-to-file devices-path {device-id: {"name": "device", "group": "production"}}
      run cli ["fleet", "group", "update", "production", "--name", "release", "--fleet", tmp]
      expect-equals "release" (read-json devices-path)[device-id]["group"]
      run cli ["fleet", "group", "move", device-id, "--to", "default", "--fleet", tmp]
      run cli ["fleet", "group", "remove", "release", "--fleet", tmp]
      expect-json [{"name": "default", "pod": "my-pod@latest"}]
          run cli ["fleet", "group", "list", "--fleet", tmp] --json

      message = run cli ["pod", "list", "--fleet", tmp] --fail
      expect (message.contains "does not configure a 'pods' backend")
      message = run cli ["fleet", "init", "--fleet", tmp, "--organization-id", device-id] --fail
      expect (message.contains "Configure backend servers and scopes in artemis.yaml")

run cli/cli.Cli args/List --json/bool=false --fail/bool=false -> any:
  ui := TestUi --json=json
  exception := catch: artemis-cli.main args --cli=(cli.with --ui=ui)
  if fail:
    expect exception is TestExit
  else:
    if exception:
      print ui.stdout
      throw exception
  return json ? json-encoding.parse ui.stdout : ui.stdout

expect-json expected/any actual/any:
  expect (json-equals expected actual)
