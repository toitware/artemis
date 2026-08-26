// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ar
import cli show Cli FileStore
import host.file
import net
import uuid show Uuid

import encoding.base64
import encoding.ubjson
import encoding.json
import fs
import host.os
import system

import .cache as cache
import .config
import .device
import .git
import .pod-specification

import .utils

import .auth-providers.auth-provider
import .sdk
import .organization
import .server-config

/**
Manages devices that have an Artemis service running on them.
*/
class Artemis:
  auth-provider_/AuthProvider? := null
  network_/net.Interface? := null

  cli_/Cli
  server-config/ServerConfig
  tmp-directory/string

  constructor --cli/Cli --.tmp-directory --.server-config:
    cli_ = cli

  /**
  Closes the manager.

  If the manager opened any connections, closes them as well.
  */
  close:
    if auth-provider_: auth-provider_.close
    if network_: network_.close
    auth-provider_ = null
    network_ = null

  /** Opens the network. */
  connect-network_:
    if network_: return
    network_ = net.open

  /**
  Returns a connected auth provider, using the $server-config to connect.

  If $authenticated is true (the default), calls $AuthProvider.ensure-authenticated.
  */
  connected-auth-provider_ --authenticated/bool=true -> AuthProvider:
    if not auth-provider_:
      connect-network_
      auth-provider_ = AuthProvider network_ server-config --cli=cli_
    if authenticated:
      auth-provider_.ensure-authenticated: | error-message |
        cli_.ui.abort "$error-message (artemis)."
    return auth-provider_

  /**
  Ensures that the user is authenticated with the Artemis server.
  */
  ensure-authenticated -> none:
    connected-auth-provider_

  /**
  Fetches the organizations with the given $id.

  Returns null if the organization doesn't exist.
  */
  get-organization --id/Uuid -> OrganizationDetailed?:
    return connected-auth-provider_.get-organization id

service-path-in-repository root/string --chip-family/string -> string:
  return "$root/src/service/run/$(chip-family).toit"

ARTEMIS-SERVICE-GIT-URL ::= "https://github.com/toitware/artemis"

get-artemis-container version-or-path/string --chip-family/string --cli/Cli -> ContainerPath:
  artemis-root-path := os.env.get "ARTEMIS_REPO_PATH"
  if artemis-root-path:
    entrypoint := service-path-in-repository artemis-root-path --chip-family=chip-family
    return ContainerPath "artemis" --entrypoint=entrypoint
  if is-dev-setup:
    git := Git --cli=cli
    artemis-path := fs.dirname system.program-path
    root := git.current-repository-root --path=artemis-path
    entrypoint := service-path-in-repository root --chip-family=chip-family
    return ContainerPath "artemis" --entrypoint=entrypoint

  url/string := ?
  if version-or-path.starts-with "http://" or version-or-path.starts-with "https://":
    url = version-or-path
  else if version-or-path.starts-with "file:/":
    return ContainerPath "artemis" --entrypoint=(version-or-path.trim --left "file:/")
  else:
    // This is a version string.
    url = ARTEMIS-SERVICE-GIT-URL

  version := version-or-path
  return ContainerPath "artemis"
      --entrypoint=(service-path-in-repository "." --chip-family=chip-family)
      --git-url=url
      --git-ref=version
