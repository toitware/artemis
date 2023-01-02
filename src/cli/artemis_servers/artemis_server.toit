// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net

import .supabase show ArtemisServerCliSupabase
import .http.base show ArtemisServerCliHttpToit
import ...shared.server_config
import ..device

/**
An abstraction for the Artemis server.
*/
interface ArtemisServerCli:
  constructor network/net.Interface server_config/ServerConfig:
    if server_config is ServerConfigSupabase:
      return ArtemisServerCliSupabase network (server_config as ServerConfigSupabase)
    if server_config is ServerConfigHttpToit:
      return ArtemisServerCliHttpToit network (server_config as ServerConfigHttpToit)
    throw "UNSUPPORTED ARTEMIS SERVER CONFIG"

  is_closed -> bool

  close -> none

  /**
  Adds a new device to the organization with the given $organization_id.

  Takes a $device_id, representing the user's chosen name for the device.
  The $device_id may be empty.
  */
  create_device_in_organization --organization_id/string --device_id/string -> Device

  /**
  Notifies the server that the device with the given $hardware_id was created.

  This operation is mostly for debugging purposes, as the $create_device_in_organization
    already has a similar effect.
  */
  notify_created --hardware_id/string
