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

class WorkspaceException:
  message/string

  constructor .message:

  stringify -> string:
    return message

workspace-error_ message/string:
  throw (WorkspaceException message)

validate-keys_ encoded/Map allowed/List context/string:
  encoded.keys.do: | key |
    if not allowed.contains key:
      workspace-error_ "$context has unknown field '$key'."

/** Describes the implementation selected for one Artemis interface. */
abstract class BackendConfig:
  name/string

  constructor.from-sub_ .name:

  /** Parses a backend configuration and resolves its server reference. */
  static from-map name/string encoded/any servers/Map -> BackendConfig:
    if encoded is not Map:
      workspace-error_ "Backend '$name' must be a map."

    type := encoded.get "type"
    if type == "file":
      return FileBackendConfig.from-map name encoded

    if type == "http":
      return HttpBackendConfig.from-map name encoded servers

    workspace-error_ "Backend '$name' has unknown type '$type'."
    unreachable

  /** Serializes this backend configuration. */
  abstract to-map -> Map

/** Stores an interface in a directory relative to the workspace file. */
class FileBackendConfig extends BackendConfig:
  directory/string

  constructor.from-map name/string encoded/Map:
    validate-keys_ encoded ["type", "directory"] "File backend '$name'"
    directory := encoded.get "directory"
    if directory is not string or directory.is-empty:
      workspace-error_ "File backend '$name' must have a non-empty 'directory'."
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

  constructor.from-map name/string encoded/Map servers/Map:
    validate-keys_ encoded ["type", "server", "endpoint", "scope"] "HTTP backend '$name'"
    server-name := encoded.get "server"
    if server-name is not string or server-name.is-empty:
      workspace-error_ "HTTP backend '$name' must reference a server."
    if not servers.contains server-name:
      workspace-error_ "HTTP backend '$name' references unknown server '$server-name'."

    endpoint := encoded.get "endpoint"
    if endpoint is not string or not endpoint.starts-with "/":
      workspace-error_ "HTTP backend '$name' must have an absolute-path 'endpoint'."
    if endpoint.starts-with "//" or endpoint.contains "?" or endpoint.contains "#":
      workspace-error_ "HTTP backend '$name' must have an endpoint without a host, query, or fragment."
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

  /** Finds a workspace at the selected directory or manifest path. */
  static find root-or-path/string -> Workspace?:
    path := file.is-directory root-or-path ? fs.join root-or-path ARTEMIS-FILE : root-or-path
    if (fs.basename path) != ARTEMIS-FILE or not file.is-file path: return null
    return load path

  /** Loads an `artemis.yaml` from $root-or-path. */
  static load root-or-path/string -> Workspace:
    path := root-or-path
    if file.is-directory path: path = fs.join path ARTEMIS-FILE
    if not file.is-file path:
      workspace-error_ "Workspace '$root-or-path' does not contain an $ARTEMIS-FILE file."

    encoded := null
    exception := catch: encoded = read-yaml path
    if exception:
      workspace-error_ "Workspace file '$path' is not valid YAML: $exception"
    return from-map encoded --path=path

  /** Parses an encoded workspace configuration. */
  static from-map encoded/any --path/string=ARTEMIS-FILE -> Workspace:
    if encoded is not Map:
      workspace-error_ "Workspace file '$path' must contain a map."
    validate-keys_ encoded ["\$schema", "servers", "backends"] "Workspace file '$path'"

    schema := encoded.get "\$schema"
    if schema != WORKSPACE-SCHEMA:
      workspace-error_ "Workspace file '$path' has unsupported schema '$schema'."

    encoded-servers := encoded.get "servers"
    if encoded-servers is not Map:
      workspace-error_ "Workspace file '$path' must contain a 'servers' map."
    credential-references := {:}
    servers := encoded-servers.map: | name encoded-server |
      if name is not string or name.is-empty:
        workspace-error_ "Workspace file '$path' contains an invalid server name."
      if encoded-server is not Map:
        workspace-error_ "Server '$name' must be a map."
      if encoded-server.contains "scope":
        workspace-error_ "Server '$name' cannot contain a fleet scope."
      if encoded-server.contains "poll_interval" or encoded-server.contains "device_headers":
        workspace-error_ "Server '$name' cannot contain embedded device configuration."
      if encoded-server.contains "admin_headers":
        workspace-error_ "Server '$name' must reference local credentials instead of embedding admin_headers."
      type := encoded-server.get "type"
      if type != "supabase" and type != "toit-http":
        workspace-error_ "Server '$name' has unknown type '$type'."
      allowed := ["type", "url", "credentials", "root_certificate_ders64"]
      if type == "supabase": allowed.add "anon"
      validate-keys_ encoded-server allowed "Server '$name'"
      url := encoded-server.get "url"
      if url is not string or not (url.starts-with "http://" or url.starts-with "https://"):
        workspace-error_ "Server '$name' must have an HTTP or HTTPS URL."
      if url.contains "?" or url.contains "#" or url.contains "@":
        workspace-error_ "Server '$name' URL must not contain credentials, a query, or a fragment."
      if encoded-server.contains "credentials":
        reference := encoded-server["credentials"]
        if reference is not string or reference.is-empty:
          workspace-error_ "Server '$name' must have a non-empty credentials reference."
        credential-references[name] = reference
      ServerConfig.from-json name encoded-server
          --der-deserializer=: base64.decode it

    encoded-backends := encoded.get "backends"
    if encoded-backends is not Map:
      workspace-error_ "Workspace file '$path' must contain a 'backends' map."
    backends := encoded-backends.map: | name encoded-backend |
      if name is not string or name.is-empty:
        workspace-error_ "Workspace file '$path' contains an invalid backend name."
      BackendConfig.from-map name encoded-backend servers

    return Workspace --path=path --servers=servers --backends=backends
        --credential-references=credential-references

  /** Returns the configuration for the backend named $name. */
  backend name/string -> BackendConfig:
    result := backends.get name
    if not result: workspace-error_ "Workspace does not configure a '$name' backend."
    return result

  /** Returns the configured fleet backend. */
  fleet -> BackendConfig:
    return backend FLEET-BACKEND

  /** Returns the configured broker backend. */
  broker -> BackendConfig:
    return backend BROKER-BACKEND

  /** Returns the configured pod backend. */
  pods -> BackendConfig:
    return backend PODS-BACKEND

  /** Returns the configured artifact backend. */
  artifacts -> BackendConfig:
    return backend ARTIFACTS-BACKEND

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
      if reference := credential-references.get name:
        encoded-servers[name]["credentials"] = reference

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
