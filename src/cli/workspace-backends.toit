// Copyright (C) 2026 Toit contributors. All rights reserved.

import cli show Cli

import .directory-fleet-store
import .fleet-store
import .server-config
import .workspace
import .brokers.server show Server
import .brokers.http.base
import .brokers.supabase show create-server-supabase-http
import .brokers.stores

/** Opens the backends selected by a workspace and closes their connections. */
class WorkspaceBackends:
  workspace/Workspace
  cli_/Cli
  servers_/Map := {:}

  constructor .workspace --cli/Cli:
    cli_ = cli

  /** Returns the configured fleet persistence strategy. */
  fleet-strategy -> FleetStoreStrategy:
    config := backend-config_ FLEET-BACKEND
    if config is not FileBackendConfig:
      cli_.ui.abort "The fleet backend currently requires type 'file'."
    return DirectoryFleetStoreStrategy
        --root=(workspace.resolve (config as FileBackendConfig).directory)
        --cli=cli_

  /** Opens the configured broker interface. */
  broker -> BrokerBackend:
    config := http-config_ BROKER-BACKEND
    return BrokerBackendHttp (server_ config.server-name)
        --endpoint=(config.endpoint.trim --right "/")
        --scope=config.scope

  /** Opens the configured pod interface. */
  pods -> PodStore:
    config := http-config_ PODS-BACKEND
    return PodStoreHttp (server_ config.server-name)
        --endpoint=(config.endpoint.trim --right "/")
        --scope=config.scope

  /** Opens the configured artifact interface. */
  artifacts -> ArtifactStore:
    config := http-config_ ARTIFACTS-BACKEND
    return ArtifactStoreHttp (server_ config.server-name)
        --endpoint=(config.endpoint.trim --right "/")
        --scope=config.scope

  http-config_ name/string -> HttpBackendConfig:
    config := backend-config_ name
    if config is not HttpBackendConfig:
      cli_.ui.abort "The '$name' backend currently requires type 'http'."
    return config as HttpBackendConfig

  backend-config_ name/string -> BackendConfig:
    config := workspace.backends.get name
    if not config: cli_.ui.abort "Workspace does not configure a '$name' backend."
    return config

  /** Resolves a server's local credentials while preserving portable settings. */
  server-config name/string -> ServerConfig:
    portable/ServerConfig := workspace.servers[name]
    reference/string? := workspace.credential-references.get name
    if not reference: return portable

    credential-config := get-server-from-config --cli=cli_ --name=reference
    encoded := portable.to-workspace-json --base64 --der-serializer=: unreachable
    encoded-credential-config := credential-config.to-json --base64 --der-serializer=: unreachable
    if credential-config.type != portable.type or encoded-credential-config["url"] != encoded["url"]:
      cli_.ui.abort "Credentials '$reference' do not match the type and URL of workspace server '$name'."
    headers := encoded-credential-config.get "admin_headers"
    if headers:
      encoded["admin_headers"] = headers
    // Supabase sessions are stored under auths.<local-server-name>.
    return ServerConfig.from-json reference encoded --der-deserializer=: unreachable

  server_ name/string -> Server:
    cached-server := servers_.get name
    if cached-server: return cached-server
    config := server-config name
    server/Server := config is ServerConfigSupabase
        ? create-server-supabase-http (config as ServerConfigSupabase)
            --cli=cli_
            --path-prefix=""
            --use-local-auth=(workspace.credential-references.contains name)
        : Server config --cli=cli_
    succeeded := false
    try:
      if workspace.credential-references.contains name:
        server.ensure-authenticated: | message/string |
          cli_.ui.abort message
      servers_[name] = server
      succeeded = true
      return server
    finally:
      if not succeeded: server.close

  close -> none:
    servers_.values.do: | server/Server | server.close
    servers_.clear
