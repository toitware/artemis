// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.file
import encoding.json
import net
import ..auth
import ..config
import ..ui
import ...shared.server_config
import .mqtt.base
import .supabase
import .http.base

/**
Responsible for allowing the Artemis CLI to talk to Artemis services on devices.
*/
interface BrokerCli implements Authenticatable:
  // TODO(florian): we probably want to add a `connect` function to this interface.
  // At the moment we require the connection to be open when artemis receives the
  // broker.

  constructor server_config/ServerConfig config/Config:
    if server_config is ServerConfigSupabase:
      return create_broker_cli_supabase (server_config as ServerConfigSupabase) config
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
  Ensures that the user is authenticated.

  If the user is not authenticated, the $block is called.
  */
  ensure_authenticated [block]

  /**
  Signs the user up with the given $email and $password.
  */
  sign_up --email/string --password/string

  /**
  Signs the user in with the given $email and $password.
  */
  sign_in --email/string --password/string

  /**
  Signs the user in using OAuth.
  */
  sign_in --provider/string --ui/Ui --open_browser

  /**
  Updates the goal state of the device with the given $device_id.

  The block is called with 2 arguments:
  - the current goal state: the configuration that the broker currently sends
    to the device. May be null if no goal state was set yet.
  - the state: the state as reported by the device. If the device
    hasn't reported its state yet, then the initial state (as stored
    by $notify_created) is used.

  The $block should return a new goal state which replaces the actual goal state.

  The $block is allowed to modify the given goal state but is still required
    to return it.
  */
  device_update_goal --device_id/string [block] -> none

  /**
  Uploads an application image with the given $app_id so that a device can fetch it.

  There may be multiple images for the same $app_id, that differ in the $word_size.
    Generally $word_size is either 32 or 64.
  */
  upload_image --app_id/string --word_size/int content/ByteArray -> none

  /**
  Uploads a firmware with the given $firmware_id so that a device can fetch it.

  The $chunks are a list of byte arrays.
  */
  upload_firmware --firmware_id/string chunks/List -> none

  /**
  Downloads a firmware chunk. Ugly interface.
  */
  download_firmware --id/string -> ByteArray

  /**
  Informs the broker that a device with the given $device_id has been provisioned.
  The $state map is the initial state of the device. Until it connects to the
    broker there is (probably) only identity information in it.
  */
  notify_created --device_id/string --state/Map -> none

with_broker server_config/ServerConfig config/Config [block]:
  broker := BrokerCli server_config config
  try:
    block.call broker
  finally:
    broker.close
