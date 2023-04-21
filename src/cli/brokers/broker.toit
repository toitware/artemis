// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.file
import encoding.json
import net
import uuid

import ..auth
import ..config
import ..event
import ..device
import ..ui
import ...shared.server_config
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

  The block is called with a $DeviceDetailed as argument:

  The $block must return a new goal state which replaces the actual goal state.

  The $block is allowed to modify the state maps of the $DeviceDetailed, but is
    still required to return the new goal state. It is not enough to just
    modify the goal map of the $DeviceDetailed.
  */
  update_goal --device_id/string [block] -> none

  /**
  Uploads an application image with the given $app_id so that a device in
    $organization_id can fetch it.

  There may be multiple images for the same $app_id, that differ in the $word_size.
    Generally $word_size is either 32 or 64.
  */
  upload_image
      --organization_id/string
      --app_id/uuid.Uuid
      --word_size/int
      content/ByteArray -> none

  /**
  Uploads a firmware with the given $firmware_id so that a device in
    $organization_id can fetch it.

  The $chunks are a list of byte arrays.
  */
  upload_firmware --organization_id/string --firmware_id/string chunks/List -> none

  /**
  Downloads a firmware chunk inside the given $organization_id.
  */
  download_firmware --organization_id/string --id/string -> ByteArray

  /**
  Informs the broker that a device with the given $device_id has been provisioned.
  The $state map is the initial state of the device. Until it connects to the
    broker there is (probably) only identity information in it.
  */
  notify_created --device_id/string --state/Map -> none

  /**
  Fetches all events of the given $types for all devices in the $device_ids list.
  If no $types are given, all events are returned.
  Returns a mapping from device-id to list of $Event s.
  At most $limit events per device are returned.
  If $since is not null, only events that are newer than $since are returned.
  */
  get_events -> Map
      --types/List?=null
      --device_ids/List
      --limit/int=10
      --since/Time?=null

  /**
  Fetches the device details for the given device ids.
  Returns a map from id to $DeviceDetailed.
  */
  get_devices --device_ids/List -> Map

with_broker server_config/ServerConfig config/Config [block]:
  broker := BrokerCli server_config config
  try:
    block.call broker
  finally:
    broker.close
