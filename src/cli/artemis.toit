// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ar
import cli show Cli FileStore
import host.file
import net
import uuid show Uuid

import encoding.base64
import encoding.ubjson
import encoding.json

import .cache as cache
import .cache show cache-key-service-image
import .config
import .device

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

  /**
  Checks whether the given $sdk version and $service version is supported by
    the Artemis server.
  */
  check-is-supported-version_ --organization-id/Uuid --sdk/string?=null --service/string?=null:
    server := connected-artemis-server_
    versions := server.list-sdk-service-versions
        --organization-id=organization-id
        --sdk-version=sdk
        --service-version=service
    if versions.is-empty:
      cli_.ui.abort "Unsupported Artemis/SDK versions ($service/$sdk)."

  notify-created --hardware-id/Uuid:
    server := connected-artemis-server_
    server.notify-created --hardware-id=hardware-id

  create-device --device-id/Uuid? --organization-id/Uuid -> Device:
    return connected-artemis-server_.create-device-in-organization
        --device-id=device-id
        --organization-id=organization-id

  /**
  Gets the Artemis service image for the given $sdk and $service versions.

  Returns a path to the cached image.
  */
  get-service-image-path -> string
      --organization-id/Uuid
      --sdk/string
      --service/string
      --chip-family/string
      --word-size/int:
    if word-size != 32 and word-size != 64: throw "INVALID_ARGUMENT"
    service-key := cache-key-service-image
        --service-version=service
        --sdk-version=sdk
        --artemis-config=server-config
        --chip-family=chip-family
        --word-size=word-size
    return cli_.cache.get-file-path service-key: | store/FileStore |
      server := connected-artemis-server_ --no-authenticated
      entry := server.list-sdk-service-versions
          --organization-id=organization-id
          --sdk-version=sdk
          --service-version=service
      if entry.is-empty:
        cli_.ui.abort "Unsupported Artemis/SDK versions."
      image-name := entry.first["image"]
      service-image-bytes := server.download-service-image image-name
      ar-reader := ar.ArReader.from-bytes service-image-bytes
      artemis-file := ar-reader.find "artemis"
      metadata := json.decode artemis-file.content
      // Reset the reader. The images should be after the metadata, but
      // doesn't hurt.
      ar-reader = ar.ArReader.from-bytes service-image-bytes
      if metadata["version"] == 1:
        if chip-family != "esp32":
          cli_.ui.abort "Unsupported chip family '$chip-family' for service $service and SDK $sdk."
        ar-file := ar-reader.find "service-$(word-size).img"
        store.save ar-file.content
      else:
        ar-file := ar-reader.find "$(chip-family)-$(word-size).img"
        store.save ar-file.content

  /**
  Fetches the organizations with the given $id.

  Returns null if the organization doesn't exist.
  */
  get-organization --id/Uuid -> OrganizationDetailed?:
    return connected-artemis-server_.get-organization id

  /**
  List all SDK/service version combinations.

  Returns a list of maps with the following keys:
  - "sdk_version": the SDK version
  - "service_version": the service version
  - "image": the name of the image

  If provided, the given $sdk-version and $service-version can be
    used to filter the results.
  */
  list-sdk-service-versions -> List
      --organization-id/Uuid
      --sdk-version/string?
      --service-version/string?:
    return connected-artemis-server_.list-sdk-service-versions
        --organization-id=organization-id
        --sdk-version=sdk-version
        --service-version=service-version
