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
import .cache show cache-key-service-image
import .config
import .device
import .git
import .pod-specification

import .utils

import .artemis-servers.artemis-server
import .brokers.broker
import .sdk
import .organization
import .server-config

/**
Manages devices that have an Artemis service running on them.
*/
class Artemis:
  artemis-server_/ArtemisServerCli? := null
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
    if artemis-server_: artemis-server_.close
    if network_: network_.close
    artemis-server_ = null
    network_ = null

  /** Opens the network. */
  connect-network_:
    if network_: return
    network_ = net.open

  /**
  Returns a connected artemis-server, using the $server-config to connect.

  If $authenticated is true (the default), calls $ArtemisServerCli.ensure-authenticated.
  */
  connected-artemis-server_ --authenticated/bool=true -> ArtemisServerCli:
    if not artemis-server_:
      connect-network_
      artemis-server_ = ArtemisServerCli network_ server-config --cli=cli_
    if authenticated:
      artemis-server_.ensure-authenticated: | error-message |
        cli_.ui.abort "$error-message (artemis)."
    return artemis-server_

  /**
  Ensures that the user is authenticated with the Artemis server.
  */
  ensure-authenticated -> none:
    connected-artemis-server_

  notify-created --hardware-id/Uuid:
    server := connected-artemis-server_
    server.notify-created --hardware-id=hardware-id

  create-device --device-id/Uuid? --organization-id/Uuid -> Device:
    return connected-artemis-server_.create-device-in-organization
        --device-id=device-id
        --organization-id=organization-id

  /**
  Fetches the organizations with the given $id.

  Returns null if the organization doesn't exist.
  */
  get-organization --id/Uuid -> OrganizationDetailed?:
    return connected-artemis-server_.get-organization id

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
