// Copyright (C) 2026 Toitware ApS. All rights reserved.

import artemis.cli.workspace show
    FileBackendConfig
    HttpBackendConfig
    Workspace
    WORKSPACE-SCHEMA
import artemis.shared.server-config show ServerConfigSupabase
import artemis.shared.json-diff show json-equals
import artemis.cli.utils show read-json read-yaml
import expect show *
import fs
import host
import host.file

main:
  test-server-indirection
  test-round-trip
  test-credential-validation
  test-yaml-file
  test-validation
  test-endpoint-validation
  test-find-errors
  test-server-decoding-errors
  test-missing-backend
  test-yaml-reader-errors
  test-json-reader-errors

test-server-indirection:
  workspace := Workspace.from-map --path="/work/artemis.yaml" --if-error=(: unreachable) {
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

  fleet := (workspace.fleet --if-error=(: unreachable)) as FileBackendConfig
  broker := (workspace.broker --if-error=(: unreachable)) as HttpBackendConfig
  pods := (workspace.pods --if-error=(: unreachable)) as HttpBackendConfig
  artifacts := (workspace.artifacts --if-error=(: unreachable)) as HttpBackendConfig

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
        "credentials": {"type": "cli-config", "name": "local-login"},
      },
    },
    "backends": {
      "broker": {
        "type": "http",
        "server": "local",
        "endpoint": "/broker",
        "scope": {"tenant": "test", "namespace": ["devices"]},
      },
    },
  }

  workspace := Workspace.from-map encoded --if-error=(: unreachable)
  decoded := Workspace.from-map workspace.to-map --if-error=(: unreachable)
  backend := (decoded.broker --if-error=(: unreachable)) as HttpBackendConfig
  expect-equals "local" backend.server-name
  expect-equals "/broker" backend.endpoint
  expect-equals "local-login" decoded.credential-references["local"]
  expect (json-equals encoded workspace.to-map)
  expect (json-equals workspace.to-map decoded.to-map)
  expect (json-equals {"tenant": "test", "namespace": ["devices"]} backend.scope.to-json)
  expect-not (decoded.to-map["servers"]["local"].contains "scope")
  expect-not (decoded.to-map["servers"]["local"].contains "admin_headers")

test-credential-validation:
  [
    ["local-login", "Server 'local' credentials must be a map with 'type' and 'name'."],
    [null, "Server 'local' credentials must be a map with 'type' and 'name'."],
    [["cli-config", "local-login"], "Server 'local' credentials must be a map with 'type' and 'name'."],
    [{"name": "local-login"}, "Server 'local' credentials have unsupported type 'null'; expected 'cli-config'."],
    [{"type": "env", "name": "TOKEN"}, "Server 'local' credentials have unsupported type 'env'; expected 'cli-config'."],
    [{"type": "cli-config"}, "Server 'local' credentials must name a non-empty CLI configuration entry."],
    [{"type": "cli-config", "name": ""}, "Server 'local' credentials must name a non-empty CLI configuration entry."],
    [{"type": "cli-config", "name": 42}, "Server 'local' credentials must name a non-empty CLI configuration entry."],
    [{"type": "cli-config", "name": "login", "token": "secret"}, "Server 'local' credential reference has unknown field 'token'."],
  ].do: | test/List |
    expect-workspace-error test[1] {
      "\$schema": WORKSPACE-SCHEMA,
      "servers": {"local": {"type": "toit-http", "url": "https://example.net", "credentials": test[0]}},
      "backends": {:},
    }

test-yaml-file:
  host.with-tmp-directory: | tmp/string |
    path := "$tmp/artemis.yaml"
    workspace := Workspace.from-map --path=path --if-error=(: unreachable) {
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
    loaded := Workspace.load tmp --if-error=(: unreachable)
    found := Workspace.find tmp --if-error=(: unreachable)
    expect (json-equals loaded.to-map found.to-map)
    fleet := (loaded.fleet --if-error=(: unreachable)) as FileBackendConfig
    expect-equals (fs.join tmp "fleet") (loaded.resolve fleet.directory)

test-validation:
  expect-workspace-error "Server 'local' must reference local credentials instead of embedding admin_headers." {
    "\$schema": WORKSPACE-SCHEMA,
    "servers": {
      "local": {"type": "toit-http", "url": "http://localhost", "admin_headers": {"Authorization": "secret"}},
    },
    "backends": {:},
  }
  expect-workspace-error "Workspace file 'artemis.yaml' has unsupported schema 'null'." {
    "servers": {:},
    "backends": {:},
  }

  expect-workspace-error "HTTP backend 'broker' references unknown server 'missing'." {
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

  expect-workspace-error "Server 'production' cannot contain a fleet scope." {
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

  expect-workspace-error "Server 'production' cannot contain embedded device configuration." {
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
  expect-workspace-error "Workspace file 'artemis.yaml' must contain a map." []
  expect-workspace-error "File backend 'fleet' must have a non-empty 'directory'." {
    "\$schema": WORKSPACE-SCHEMA,
    "servers": {:},
    "backends": {"fleet": {"type": "file", "directory": ""}},
  }
  expect-workspace-error "File backend 'fleet' has unknown field 'path'." {
    "\$schema": WORKSPACE-SCHEMA,
    "servers": {:},
    "backends": {"fleet": {"type": "file", "path": "fleet"}},
  }
  expect-workspace-error "Backend 'fleet' has unknown type 'unknown'." {
    "\$schema": WORKSPACE-SCHEMA,
    "servers": {:},
    "backends": {"fleet": {"type": "unknown"}},
  }

expect-workspace-error message/string encoded/any:
  Workspace.from-map encoded --if-error=: | diagnostic/string |
    expect-equals message diagnostic
    return
  expect false

test-endpoint-validation:
  ["//other.example/path", "/pods?key=value", "/pods#fragment"].do: | endpoint/string |
    expect-workspace-error "HTTP backend 'pods' must have an endpoint without a host, query, or fragment." {
      "\$schema": WORKSPACE-SCHEMA,
      "servers": {"local": {"type": "toit-http", "url": "https://example.net"}},
      "backends": {"pods": {"type": "http", "server": "local", "endpoint": endpoint}},
    }
  expect-workspace-error "Server 'local' has unknown field 'credential'." {
    "\$schema": WORKSPACE-SCHEMA,
    "servers": {"local": {"type": "toit-http", "url": "https://example.net", "credential": "typo"}},
    "backends": {:},
  }

test-find-errors:
  host.with-tmp-directory: | tmp/string |
    path := fs.join tmp "artemis.yaml"
    expect-equals null (Workspace.find tmp --if-error=(: unreachable))
    expect-equals null (Workspace.find path --if-error=(: unreachable))

    Workspace.load tmp --if-error=: | message/string |
      expect-equals "Workspace '$tmp' does not contain an artemis.yaml file." message
      continue.with-tmp-directory
    expect false
  host.with-tmp-directory: | tmp/string |
    path := fs.join tmp "artemis.yaml"
    file.write-contents --path=path "["
    Workspace.find tmp --if-error=: | message/string |
      expect (message.starts-with "Failed to read workspace YAML '$path':")
      continue.with-tmp-directory
    expect false
  host.with-tmp-directory: | tmp/string |
    path := fs.join tmp "artemis.yaml"
    file.write-contents --path=path "servers: {}\nbackends: {}\n"
    Workspace.find path --if-error=: | message/string |
      expect-equals "Workspace file '$path' has unsupported schema 'null'." message
      continue.with-tmp-directory
    expect false

test-server-decoding-errors:
  [
    {"type": "supabase", "url": "https://example.net"},
    {"type": "toit-http", "url": "https://example.net", "root_certificate_ders64": ["!"]},
  ].do: | server/Map |
    Workspace.from-map {
      "\$schema": WORKSPACE-SCHEMA,
      "servers": {"local": server},
      "backends": {:},
    } --if-error=: | message/string |
      expect (message.starts-with "Server 'local' has invalid connection settings:")
      continue.do
    expect false

test-missing-backend:
  workspace := Workspace.from-map {
    "\$schema": WORKSPACE-SCHEMA,
    "servers": {:},
    "backends": {:},
  } --if-error=(: unreachable)
  workspace.fleet --if-error=: | message/string |
    expect-equals "Workspace does not configure a 'fleet' backend." message
    return
  expect false

test-yaml-reader-errors:
  host.with-tmp-directory: | tmp/string |
    path := fs.join tmp "metadata.yaml"
    calls := 0
    result := read-yaml path --if-error=: | exception |
      expect ("$exception".contains path)
      calls++
      "missing"
    expect-equals "missing" result
    expect-equals 1 calls

    file.write-contents --path=path "["
    result = read-yaml path --if-error=: | exception |
      expect-equals "INVALID_YAML_DOCUMENT" exception
      calls++
      "invalid"
    expect-equals "invalid" result
    expect-equals 2 calls

    file.write-contents --path=path "null"
    expect-equals null (read-yaml path --if-error=(: unreachable))
    file.write-contents --path=path "false"
    expect-equals false (read-yaml path --if-error=(: unreachable))

test-json-reader-errors:
  host.with-tmp-directory: | tmp/string |
    path := fs.join tmp "groups.json"
    calls := 0
    result := read-json path --if-error=: | exception |
      expect ("$exception".contains path)
      calls++
      "missing"
    expect-equals "missing" result
    expect-equals 1 calls

    file.write-contents --path=path "["
    result = read-json path --if-error=: | exception |
      expect-not ("$exception".is-empty)
      calls++
      "invalid"
    expect-equals "invalid" result
    expect-equals 2 calls

    file.write-contents --path=path "null"
    expect-equals null (read-json path --if-error=(: unreachable))
    file.write-contents --path=path "false"
    expect-equals false (read-json path --if-error=(: unreachable))
