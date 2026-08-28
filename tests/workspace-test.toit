// Copyright (C) 2026 Toitware ApS. All rights reserved.

import artemis.cli.workspace show
    FileBackendConfig
    HttpBackendConfig
    Workspace
    WorkspaceException
    WORKSPACE-SCHEMA
import artemis.shared.server-config show ServerConfigSupabase
import expect show *
import fs
import host
import host.file

main:
  test-server-indirection
  test-round-trip
  test-yaml-file
  test-validation

test-server-indirection:
  workspace := Workspace.from-map --path="/work/artemis.yaml" {
    "\$schema": WORKSPACE-SCHEMA,
    "servers": {
      "production": {
        "type": "supabase",
        "url": "https://example.supabase.co/",
        "anon": "anon-key",
      },
    },
    "backends": {
      "fleet": {
        "type": "file",
        "directory": "fleet",
      },
      "broker": {
        "type": "http",
        "server": "production",
        "endpoint": "/functions/v2/broker",
      },
      "pods": {
        "type": "http",
        "server": "production",
        "endpoint": "/functions/v2/pods",
      },
      "artifacts": {
        "type": "http",
        "server": "production",
        "endpoint": "/functions/v2/artifacts",
      },
    },
  }

  fleet := workspace.fleet as FileBackendConfig
  broker := workspace.broker as HttpBackendConfig
  pods := workspace.pods as HttpBackendConfig
  artifacts := workspace.artifacts as HttpBackendConfig

  expected-fleet-path := fs.join (fs.dirname workspace.path) fleet.directory
  expect-equals expected-fleet-path (workspace.resolve fleet.directory)
  expect-identical broker.server-config pods.server-config
  expect-identical broker.server-config artifacts.server-config
  expect broker.server-config is ServerConfigSupabase
  expect-equals "https://example.supabase.co"
      (broker.server-config as ServerConfigSupabase).url

test-round-trip:
  encoded := {
    "\$schema": WORKSPACE-SCHEMA,
    "servers": {
      "local": {
        "type": "toit-http",
        "url": "http://localhost:4998",
        "admin_headers": {"Authorization": "Bearer token"},
      },
    },
    "backends": {
      "broker": {
        "type": "http",
        "server": "local",
        "endpoint": "/broker",
      },
    },
  }

  workspace := Workspace.from-map encoded
  decoded := Workspace.from-map workspace.to-map
  backend := decoded.broker as HttpBackendConfig
  expect-equals "local" backend.server-name
  expect-equals "/broker" backend.endpoint
  server-map := backend.server-config.to-json
      --base64
      --der-serializer=: unreachable
  expect-equals "Bearer token" server-map["admin_headers"]["Authorization"]

test-yaml-file:
  host.with-tmp-directory: | tmp/string |
    path := "$tmp/artemis.yaml"
    workspace := Workspace.from-map --path=path {
      "\$schema": WORKSPACE-SCHEMA,
      "servers": {:},
      "backends": {
        "fleet": {
          "type": "file",
          "directory": "fleet",
        },
      },
    }
    workspace.write

    expect (file.is-file path)
    loaded := Workspace.load tmp
    fleet := loaded.fleet as FileBackendConfig
    expect-equals "$tmp/fleet" (loaded.resolve fleet.directory)

test-validation:
  expect-workspace-error "Workspace file 'artemis.yaml' has unsupported schema 'null'.":
    Workspace.from-map {
      "servers": {:},
      "backends": {:},
    }

  expect-workspace-error "HTTP backend 'broker' references unknown server 'missing'.":
    Workspace.from-map {
      "\$schema": WORKSPACE-SCHEMA,
      "servers": {:},
      "backends": {
        "broker": {
          "type": "http",
          "server": "missing",
          "endpoint": "/broker",
        },
      },
    }

  expect-workspace-error "Server 'production' cannot contain a fleet scope.":
    Workspace.from-map {
      "\$schema": WORKSPACE-SCHEMA,
      "servers": {
        "production": {
          "type": "toit-http",
          "url": "https://example.com",
          "scope": "organization",
        },
      },
      "backends": {:},
    }

  expect-workspace-error "Server 'production' cannot contain embedded device configuration.":
    Workspace.from-map {
      "\$schema": WORKSPACE-SCHEMA,
      "servers": {
        "production": {
          "type": "toit-http",
          "url": "https://example.com",
          "poll_interval": 20_000_000,
        },
      },
      "backends": {:},
    }

expect-workspace-error message/string [block]:
  exception := catch: block.call
  expect exception is WorkspaceException
  expect-equals message (exception as WorkspaceException).message
