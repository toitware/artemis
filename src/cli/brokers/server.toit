// Copyright (C) 2026 Toitware ApS. All rights reserved.

import cli show Cli

import ..auth
import ...shared.scope show Scope
import ...shared.server-config
import .supabase
import .http.base

/**
Shared connection to a configured Artemis server.

The server owns transport, authentication, and scope. Implementations of the
  individual broker and storage interfaces use the same server without being
  bundled into one backend object.
*/
interface Server implements Authenticatable:
  constructor server-config/ServerConfig --cli/Cli:
    if server-config is ServerConfigSupabase:
      return create-server-supabase-http
          (server-config as ServerConfigSupabase)
          --cli=cli
    if server-config is ServerConfigHttp:
      return create-server-http-toit (server-config as ServerConfigHttp)
    throw "Unknown server config type"

  /** Closes this server connection. */
  close -> none

  /** Whether this server connection is closed. */
  is-closed -> bool

  /** A unique ID that can be used for caching. */
  id -> string

  /** Scope used by implementations connected to this server. */
  scope -> Scope

  /** Sends a request using this server's transport and authentication. */
  send-request method/string path/string data/any=null -> any
      --query-parameters/Map?=null
      --binary-request/bool=false
      --binary-response/bool=false

  /** See $Authenticatable.ensure-authenticated. */
  ensure-authenticated [block]

  /** See $Authenticatable.sign-up. */
  sign-up --email/string --password/string

  /** See $(Authenticatable.sign-in --email --password). */
  sign-in --email/string --password/string

  /** See $(Authenticatable.sign-in --provider --cli --open-browser). */
  sign-in --provider/string --cli/Cli --open-browser

  /** See $Authenticatable.update. */
  update --email/string? --password/string?

  /** See $Authenticatable.logout. */
  logout

with-server server-config/ServerConfig --cli/Cli [block]:
  server := Server server-config --cli=cli
  try:
    block.call server
  finally:
    server.close
