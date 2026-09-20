// Copyright (C) 2026 Toit contributors. All rights reserved.

import artemis.cli.workspace show Workspace WORKSPACE-SCHEMA
import artemis.cli.workspace-backends show WorkspaceBackends
import artemis.cli.server-config show ServerConfigHttp ServerConfigSupabase add-server-to-config
import artemis.cli.brokers.http.base show BrokerBackendHttp PodStoreHttp
import artemis.cli as artemis-cli
import artemis.shared.json-diff show json-equals
import cli
import encoding.json
import expect show *
import fs
import host
import http
import net
import uuid show Uuid

import .utils show TestUi TestExit with-tmp-config-cli

DEVICE-ID ::= "00000000-0000-0000-0000-000000000001"

main:
  network := net.open
  first := network.tcp-listen 0
  second := network.tcp-listen 0
  requests := []
  first-server := http.Server --max-tasks=8
  second-server := http.Server --max-tasks=8
  serve := :: | request/http.RequestIncoming writer/http.ResponseWriter |
    bytes := request.body.read-all
    path := request.query.resource
    requests.add {
      "path": path,
      "authorization": request.headers.single "Authorization",
      "apikey": request.headers.single "apikey",
      "body": bytes,
      "query": request.query.parameters,
    }
    response := path.ends-with "/descriptions" ? "17" : "[]"
    writer.headers.set "Content-Length" "$(response.size)"
    writer.out.write response
  first-task := task:: first-server.listen first serve
  second-task := task:: second-server.listen second serve
  try:
    host.with-tmp-directory: | tmp/string |
      with-tmp-config-cli: | cli/cli.Cli |
        first-url := "http://localhost:$(first.local-address.port)"
        second-url := "http://localhost:$(second.local-address.port)"
        add-server-to-config --cli=cli
            ServerConfigHttp "local-login" --url=first-url --admin-headers={"Authorization": "Bearer local-secret"}
        workspace := Workspace.from-map --path=(fs.join tmp "artemis.yaml") {
          "\$schema": WORKSPACE-SCHEMA,
          "servers": {
            "shared": {"type": "toit-http", "url": first-url, "credentials": "local-login"},
            "artifacts": {"type": "toit-http", "url": second-url},
            "public": {"type": "supabase", "url": second-url, "anon": "public-key"},
          },
          "backends": {
            "fleet": {"type": "file", "directory": "fleet"},
            "broker": {"type": "http", "server": "shared", "endpoint": "/custom/goals", "scope": {"tenant": "broker"}},
            "pods": {"type": "http", "server": "shared", "endpoint": "/custom/pods", "scope": "pod-scope"},
            "artifacts": {"type": "http", "server": "artifacts", "endpoint": "/separate/artifacts", "scope": {"tenant": "artifacts"}},
            "public-pods": {"type": "http", "server": "public", "endpoint": "/functions/v1/pod-store"},
          },
        }
        workspace.write
        backends := WorkspaceBackends workspace --cli=cli
        try:
          broker := backends.broker
          pods := backends.pods
          expect-identical (broker as BrokerBackendHttp).server (pods as PodStoreHttp).server
          broker.notify-created --device-id=(Uuid.parse DEVICE-ID) --state={:}
          expect-equals "/custom/goals/devices" requests.last["path"]
          expect (json-equals {"tenant": "broker"} (json.decode requests.last["body"])["organization_id"])
          expect-equals "Bearer local-secret" requests.last["authorization"]

          expect-equals 17
              pods.pod-registry-description-upsert --fleet-id=(Uuid.parse DEVICE-ID) --name="app" --description=null
          expect-equals "/custom/pods/descriptions" requests.last["path"]
          expect-equals "pod-scope" (json.decode requests.last["body"])["organization_id"]

          backends.artifacts.upload-image --app-id=(Uuid.parse DEVICE-ID) --word-size=32 #[1, 2, 3]
          expect-equals "/separate/artifacts/images" requests.last["path"]
          expect (json-equals {"tenant": "artifacts"} (json.parse requests.last["query"]["scope"]))
          expect-equals null requests.last["authorization"]
          expect-bytes-equal #[1, 2, 3] requests.last["body"]
          expect-not ((json.encode workspace.to-map).to-string.contains "local-secret")

          // Supabase uses the explicit endpoint once and has no implicit local session.
          public-workspace := Workspace.from-map {
            "\$schema": WORKSPACE-SCHEMA,
            "servers": {"public": workspace.to-map["servers"]["public"]},
            "backends": {"pods": workspace.to-map["backends"]["public-pods"]},
          }
          public-backends := WorkspaceBackends public-workspace --cli=cli
          try:
            cli.config["auths.public"] = {"access_token": "must-not-be-used"}
            public-backends.pods.pod-registry-descriptions --fleet-id=(Uuid.parse DEVICE-ID)
            expect-equals "/functions/v1/pod-store/descriptions/query" requests.last["path"]
            expect-equals "Bearer public-key" requests.last["authorization"]
            expect-equals "public-key" requests.last["apikey"]
          finally:
            public-backends.close

          add-server-to-config --cli=cli
              ServerConfigSupabase "supabase-login" --url=second-url --anon="public-key"
          cli.config["auths.supabase-login"] = {
            "access_token": "session-secret",
            "refresh_token": "refresh-secret",
            "token_type": "bearer",
            "expires_at_epoch_ms": (Time.now + (Duration --h=1)).ms-since-epoch,
          }
          authenticated := public-workspace.to-map
          authenticated["servers"]["public"]["credentials"] = "supabase-login"
          authenticated-backends := WorkspaceBackends (Workspace.from-map authenticated) --cli=cli
          try:
            authenticated-backends.pods.pod-registry-descriptions --fleet-id=(Uuid.parse DEVICE-ID)
            expect-equals "Bearer session-secret" requests.last["authorization"]
            expect-equals "/functions/v1/pod-store/descriptions/query" requests.last["path"]
          finally:
            authenticated-backends.close

          artemis-cli.main ["fleet", "init", "--fleet", tmp] --cli=(cli.with --ui=TestUi)
          ui := TestUi --json
          artemis-cli.main ["pod", "list", "--fleet", tmp] --cli=(cli.with --ui=ui)
          expect (json.parse ui.stdout).is-empty
          expect-equals "/custom/pods/descriptions/query" requests.last["path"]

          // A local login for a different URL must never be used for this workspace.
          add-server-to-config --cli=cli
              ServerConfigHttp "local-login" --url=second-url --admin-headers={"Authorization": "Bearer other-secret"}
          rejected := WorkspaceBackends workspace --cli=(cli.with --ui=TestUi)
          count := requests.size
          try:
            exception := catch: rejected.broker
            expect exception is TestExit
            expect-equals count requests.size
          finally:
            rejected.close
        finally:
          backends.close
  finally:
    first.close
    second.close
    first-task.cancel
    second-task.cancel
    network.close
