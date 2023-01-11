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

  /** Returns the used-id of the authenticated user. */
  get_current_user_id -> string

  /**
  Fetches list of organizations the user has access to.

  The returned list contains instances of type $Organization.
  */
  get_organizations -> List

  /**
  Fetches the organizations with the given $id.

  Returns null if the organization doesn't exist.
  */
  get_organization id/string -> DetailedOrganization?

  /** Creates a new organization with the given $name. */
  create_organization name/string -> Organization

  /**
  Gets a list of members.

  Each entry is a map consisting of the "id" and "role".
  */
  get_organization_members id/string -> List

  /**
  Adds the user with $user_id as a new member to the organization
    with $organization_id.
  */
  organization_member_add --organization_id/string --user_id/string --role/string

  /**
  Removes the user with $user_id from the organization with
    $organization_id.
  */
  organization_member_remove --organization_id/string --user_id/string

  /**
  Updates the role of the user with $user_id in the organization
    with $organization_id.
  */
  organization_member_set_role --organization_id/string --user_id/string --role/string

  /**
  Gets the profile of the user with the given ID.

  If no user ID is given, the profile of the current user is returned.
  Returns null, if no user with the given ID exists.
  */
  get_profile --user_id/string?=null -> Map?

  /**
  Updates the profile of the current user.
  */
  // TODO(florian): add support for changing the email.
  update_profile --name/string

  /**
  List all SDK/service version combinations.

  Returns a list of maps with the following keys
  - "sdk_version": the SDK version
  - "service_version": the service version
  - "image": the name of the image

  If provided, the given $sdk_version and $service_version can be
    used to filter the results.
  */
  list_sdk_service_versions --sdk_version/string?=null --service_version/string?=null -> List

  /**
  Downloads the given $image.

  The $image must be a valid image name, as returned by
    $list_sdk_service_versions.
  */
  download_service_image image/string -> ByteArray

with_server server_config/ServerConfig config/Config [block]:
  network := net.open
  server/ArtemisServerCli? := null
  try:
    server = ArtemisServerCli network server_config config
    block.call server
  finally:
    if server: server.close
    network.close
