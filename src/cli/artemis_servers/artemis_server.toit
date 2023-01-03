// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net

import .supabase show ArtemisServerCliSupabase
import .http.base show ArtemisServerCliHttpToit
import ...shared.server_config
import ..config
import ..device
import ..organization

/**
An abstraction for the Artemis server.
*/
interface ArtemisServerCli:
  constructor network/net.Interface server_config/ServerConfig config/Config:
    if server_config is ServerConfigSupabase:
      return ArtemisServerCliSupabase network (server_config as ServerConfigSupabase) config
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

  /** Fetches list of $Organization s  the user has access to. */
  get_organizations -> List

  /** Creates a new organization with the given $name. */
  create_organization name/string -> Organization
