// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.file
import encoding.json
import ...shared.server_config
import .mqtt.base
import .postgrest.supabase
import .http.base

/**
Responsible for allowing the Artemis CLI to talk to Artemis services on devices.
*/
interface BrokerCli:
  // TODO(florian): we probably want to add a `connect` function to this interface.
  // At the moment we require the connection to be open when artemis receives the
  // broker.

  constructor server_config/ServerConfig:
    if server_config is ServerConfigSupabase:
      return create_broker_cli_supabase (server_config as ServerConfigSupabase)
    if server_config is ServerConfigMqtt:
      return create_broker_cli_mqtt (server_config as ServerConfigMqtt)
    if server_config is ServerConfigHttpToit:
      return create_broker_cli_http_toit (server_config as ServerConfigHttpToit)
    throw "Unknown broker config type"

  /** Closes this broker. */
  close -> none

  /** Whether this broker is closed. */
  is_closed -> bool

  /**
  A unique ID of the broker that can be used for caching.
  May contain "/", in which case the cache will use subdirectories.
  */
  id -> string

  /**
  Invokes the $block with the current configuration (a Map) of $device_id and
    updates the device's configuration with the new map that is returned from the block.

  The $block is allowed to modify the given configuration but is still required
    to return it.
  */
  device_update_config --device_id/string [block] -> none

  /**
  Uploads an application image with the given $app_id so that a device can fetch it.

  There may be multiple images for the same $app_id, that differ in the $bits size.
    Generally $bits is either 32 or 64.
  */
  upload_image --app_id/string --bits/int content/ByteArray -> none

  /**
  Uploads a firmware with the given $firmware_id so that a device can fetch it.

  The $chunks are a list of byte arrays.
  */
  upload_firmware --firmware_id/string chunks/List -> none

  /**
  Downloads a firmware chunk. Ugly interface.
  */
  download_firmware --id/string -> ByteArray
