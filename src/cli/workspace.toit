// Copyright (C) 2026 Toitware ApS. All rights reserved.

import encoding.base64
import fs
import host.file

import .server-config
import .utils show read-yaml write-yaml-to-file
import ..shared.scope show Scope

ARTEMIS-FILE ::= "artemis.yaml"
WORKSPACE-SCHEMA ::= "https://toit.io/schemas/artemis/workspace/v1.json"

FLEET-BACKEND ::= "fleet"
BROKER-BACKEND ::= "broker"
PODS-BACKEND ::= "pods"
ARTIFACTS-BACKEND ::= "artifacts"

workspace-error_ message/string [--if-error]:
  if-error.call message
  unreachable

validate-keys_ encoded/Map allowed/List context/string [--if-error]:
  encoded.keys.do: | key |
    if not allowed.contains key:
      workspace-error_ "$context has unknown field '$key'." --if-error=if-error

/** Describes the implementation selected for one Artemis interface. */
abstract class BackendConfig:
  name/string

  constructor.from-sub_ .name:

  /**
  Parses a backend configuration and resolves its server reference.

  Calls $if-error with a diagnostic on invalid input. The block must not return.
  */
  static from-map name/string encoded/any servers/Map [--if-error] -> BackendConfig:
    if encoded is not Map:
      workspace-error_ "Backend '$name' must be a map." --if-error=if-error

    type := encoded.get "type"
    if type == "file":
      return FileBackendConfig.from-map name encoded --if-error=if-error

    if type == "http":
      return HttpBackendConfig.from-map name encoded servers --if-error=if-error

    workspace-error_ "Backend '$name' has unknown type '$type'." --if-error=if-error
    unreachable

  /** Serializes this backend configuration. */
  abstract to-map -> Map

/** Stores an interface in a directory relative to the workspace file. */
class FileBackendConfig extends BackendConfig:
  directory/string

  constructor.from-map name/string encoded/Map [--if-error]:
    validate-keys_ encoded ["type", "directory"] "File backend '$name'" --if-error=if-error
    directory := encoded.get "directory"
    if directory is not string or directory.is-empty:
      workspace-error_ "File backend '$name' must have a non-empty 'directory'." --if-error=if-error
    return FileBackendConfig name --directory=directory

  constructor name/string --.directory:
    super.from-sub_ name

  to-map -> Map:
    return {
      "type": "file",
      "directory": directory,
    }

/** Accesses an interface through a named server and relative endpoint. */
class HttpBackendConfig extends BackendConfig:
  server-config/ServerConfig
  endpoint/string
  scope/Scope

  constructor.from-map name/string encoded/Map servers/Map [--if-error]:
    validate-keys_ encoded ["type", "server", "endpoint", "scope"] "HTTP backend '$name'"
        --if-error=if-error
    server-name := encoded.get "server"
    if server-name is not string or server-name.is-empty:
      workspace-error_ "HTTP backend '$name' must reference a server." --if-error=if-error
    if not servers.contains server-name:
      workspace-error_ "HTTP backend '$name' references unknown server '$server-name'." --if-error=if-error

    endpoint := encoded.get "endpoint"
    if endpoint is not string or not endpoint.starts-with "/":
      workspace-error_ "HTTP backend '$name' must have an absolute-path 'endpoint'." --if-error=if-error
    if endpoint.starts-with "//" or endpoint.contains "?" or endpoint.contains "#":
      workspace-error_ "HTTP backend '$name' must have an endpoint without a host, query, or fragment."
          --if-error=if-error
    return HttpBackendConfig name
        --server-config=servers[server-name]
        --endpoint=endpoint
        --scope=(Scope (encoded.get "scope"))

  constructor name/string --.server-config --.endpoint --.scope=(Scope null):
    super.from-sub_ name

  server-name -> string:
    return server-config.name

  to-map -> Map:
    return {
      "type": "http",
      "server": server-name,
      "endpoint": endpoint,
      "scope": scope.to-json,
    }

/**
Configuration and local context used by Artemis.

Named servers own reusable connection settings and references to local
  credentials. Backend configurations select independently which server,
  implementation, and scope to use.
*/
class Workspace:
  path/string
  servers/Map
  backends/Map
  credential-references/Map

  constructor --.path --.servers --.backends --.credential-references={:}:

  /**
  Finds a workspace at the selected directory or manifest path.

  Returns null if no workspace file exists at the selected location.
  Calls $if-error with a diagnostic if the file cannot be loaded or is invalid.
    The block must not return.
  */
  static find root-or-path/string [--if-error] -> Workspace?:
    path := file.is-directory root-or-path ? fs.join root-or-path ARTEMIS-FILE : root-or-path
    if (fs.basename path) != ARTEMIS-FILE or not file.is-file path: return null
    return load path --if-error=if-error

  /**
  Loads an `artemis.yaml` from $root-or-path.

  Calls $if-error with a diagnostic if the file cannot be loaded or is invalid.
    The block must not return.
  */
  static load root-or-path/string [--if-error] -> Workspace:
    path := root-or-path
    if file.is-directory path: path = fs.join path ARTEMIS-FILE
    if not file.is-file path:
      workspace-error_ "Workspace '$root-or-path' does not contain an $ARTEMIS-FILE file."
          --if-error=if-error

    encoded := read-yaml path --if-error=: | exception |
      workspace-error_ "Failed to read workspace YAML '$path': $exception" --if-error=if-error
    return from-map encoded --path=path --if-error=if-error

  /**
  Parses an encoded workspace configuration.

  Calls $if-error with a diagnostic on invalid input. The block must not return.
  */
  static from-map encoded/any --path/string=ARTEMIS-FILE [--if-error] -> Workspace:
    if encoded is not Map:
      workspace-error_ "Workspace file '$path' must contain a map." --if-error=if-error
    validate-keys_ encoded ["\$schema", "servers", "backends"] "Workspace file '$path'"
        --if-error=if-error

    schema := encoded.get "\$schema"
    if schema != WORKSPACE-SCHEMA:
      workspace-error_ "Workspace file '$path' has unsupported schema '$schema'." --if-error=if-error

    encoded-servers := encoded.get "servers"
    if encoded-servers is not Map:
      workspace-error_ "Workspace file '$path' must contain a 'servers' map." --if-error=if-error
    credential-references := {:}
    servers := encoded-servers.map: | name encoded-server |
      if name is not string or name.is-empty:
        workspace-error_ "Workspace file '$path' contains an invalid server name." --if-error=if-error
      if encoded-server is not Map:
        workspace-error_ "Server '$name' must be a map." --if-error=if-error
      if encoded-server.contains "scope":
        workspace-error_ "Server '$name' cannot contain a fleet scope." --if-error=if-error
      if encoded-server.contains "poll_interval" or encoded-server.contains "device_headers":
        workspace-error_ "Server '$name' cannot contain embedded device configuration." --if-error=if-error
      if encoded-server.contains "admin_headers":
        workspace-error_ "Server '$name' must reference local credentials instead of embedding admin_headers."
            --if-error=if-error
      type := encoded-server.get "type"
      if type != "supabase" and type != "toit-http":
        workspace-error_ "Server '$name' has unknown type '$type'." --if-error=if-error
      allowed := ["type", "url", "credentials", "root_certificate_ders64"]
      if type == "supabase": allowed.add "anon"
      validate-keys_ encoded-server allowed "Server '$name'" --if-error=if-error
      url := encoded-server.get "url"
      if url is not string or not (url.starts-with "http://" or url.starts-with "https://"):
        workspace-error_ "Server '$name' must have an HTTP or HTTPS URL." --if-error=if-error
      if url.contains "?" or url.contains "#" or url.contains "@":
        workspace-error_ "Server '$name' URL must not contain credentials, a query, or a fragment."
            --if-error=if-error
      if encoded-server.contains "credentials":
        reference := encoded-server["credentials"]
        if reference is not Map:
          workspace-error_ "Server '$name' credentials must be a map with 'type' and 'name'."
              --if-error=if-error
        validate-keys_ reference ["type", "name"] "Server '$name' credential reference" --if-error=if-error
        credential-type := reference.get "type"
        if credential-type != "cli-config":
          workspace-error_ "Server '$name' credentials have unsupported type '$credential-type'; expected 'cli-config'."
              --if-error=if-error
        credential-name := reference.get "name"
        if credential-name is not string or credential-name.is-empty:
          workspace-error_ "Server '$name' credentials must name a non-empty CLI configuration entry."
              --if-error=if-error
        credential-references[name] = credential-name
      config/ServerConfig? := null
      exception := catch:
        config = ServerConfig.from-json name encoded-server
            --der-deserializer=: base64.decode it
      if exception:
        workspace-error_ "Server '$name' has invalid connection settings: $exception" --if-error=if-error
      config

    encoded-backends := encoded.get "backends"
    if encoded-backends is not Map:
      workspace-error_ "Workspace file '$path' must contain a 'backends' map." --if-error=if-error
    backends := encoded-backends.map: | name encoded-backend |
      if name is not string or name.is-empty:
        workspace-error_ "Workspace file '$path' contains an invalid backend name." --if-error=if-error
      BackendConfig.from-map name encoded-backend servers --if-error=if-error

    return Workspace --path=path --servers=servers --backends=backends
        --credential-references=credential-references

  /**
  Returns the configuration for the backend named $name.

  Calls $if-error with a diagnostic if the backend is missing. The block must not return.
  */
  backend name/string [--if-error] -> BackendConfig:
    result := backends.get name
    if not result:
      workspace-error_ "Workspace does not configure a '$name' backend." --if-error=if-error
    return result

  /** Returns the configured fleet backend. */
  fleet [--if-error] -> BackendConfig:
    return backend FLEET-BACKEND --if-error=if-error

  /** Returns the configured broker backend. */
  broker [--if-error] -> BackendConfig:
    return backend BROKER-BACKEND --if-error=if-error

  /** Returns the configured pod backend. */
  pods [--if-error] -> BackendConfig:
    return backend PODS-BACKEND --if-error=if-error

  /** Returns the configured artifact backend. */
  artifacts [--if-error] -> BackendConfig:
    return backend ARTIFACTS-BACKEND --if-error=if-error

  /** Resolves a relative workspace path against the workspace directory. */
  resolve path/string -> string:
    if fs.is-absolute path: return path
    return fs.join (fs.dirname this.path) path

  /** Serializes this workspace configuration. */
  to-map -> Map:
    encoded-servers := {:}
    servers.keys.sort.do: | name/string |
      server-config/ServerConfig := servers[name]
      encoded-servers[name] = server-config.to-workspace-json
          --base64
          --der-serializer=: unreachable
      encoded-servers[name].remove "admin_headers"
      reference := credential-references.get name
      if reference:
        encoded-servers[name]["credentials"] = {"type": "cli-config", "name": reference}

    encoded-backends := {:}
    backends.keys.sort.do: | name/string |
      backend-config/BackendConfig := backends[name]
      encoded-backends[name] = backend-config.to-map

    return {
      "\$schema": WORKSPACE-SCHEMA,
      "servers": encoded-servers,
      "backends": encoded-backends,
    }

  /** Writes this workspace to its configured $path. */
  write -> none:
    write-yaml-to-file path to-map
