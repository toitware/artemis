// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show Cli
import log
import net
import uuid show Uuid

import .supabase show ArtemisServerCliSupabase
import .http.base show ArtemisServerCliHttpToit
import ...shared.server-config
import ..auth
import ..config
import ..device
import ..organization

/**
An abstraction for the Artemis server.
*/
interface ArtemisServerCli implements Authenticatable:
  constructor network/net.Interface server-config/ServerConfig --cli/Cli:
    if server-config is ServerConfigSupabase:
      return ArtemisServerCliSupabase network (server-config as ServerConfigSupabase) --cli=cli
    if server-config is ServerConfigHttp:
      return ArtemisServerCliHttpToit network (server-config as ServerConfigHttp) --cli=cli
    throw "UNSUPPORTED ARTEMIS SERVER CONFIG"

  is-closed -> bool

  close -> none

  /**
  Ensures that the user is authenticated.

  If the user is not authenticated, the $block is called.
  */
  ensure-authenticated [block]

  /**
  Signs the user up with the given $email and $password.
  */
  sign-up --email/string --password/string

  /**
  Signs the user in with the given $email and $password.
  */
  sign-in --email/string --password/string

  /**
  Signs the user in using OAuth.
  */
  sign-in --provider/string --open-browser/bool --cli/Cli

  /**
  Updates the user's email and/or password.
  */
  update --email/string? --password/string?

  /**
  Signs the user out.
  */
  logout

  /**
  Adds a new device to the organization with the given $organization-id.

  Takes a $device-id, representing the user's chosen name for the device.
  The $device-id may be null in which case the server creates an alias.
  */
  create-device-in-organization --organization-id/Uuid --device-id/Uuid? -> Device

  /**
  Notifies the server that the device with the given $hardware-id was created.

  This operation is mostly for debugging purposes, as the $create-device-in-organization
    already has a similar effect.
  */
  notify-created --hardware-id/Uuid

  /** Returns the used-id of the authenticated user. */
  get-current-user-id -> string

  /**
  Fetches list of organizations the user has access to.

  The returned list contains instances of type $Organization.
  */
  get-organizations -> List

  /**
  Fetches the organizations with the given $id.

  Returns null if the organization doesn't exist.
  */
  get-organization id/Uuid -> OrganizationDetailed?

  /** Creates a new organization with the given $name. */
  create-organization name/string -> Organization

  /**
  Updates the given organization.
  */
  update-organization organization-id/Uuid --name/string -> none

  /**
  Gets a list of members.

  Each entry is a map consisting of the "id" and "role".
  */
  get-organization-members organization-id/Uuid -> List

  /**
  Adds the user with $user-id as a new member to the organization
    with $organization-id.
  */
  organization-member-add --organization-id/Uuid --user-id/Uuid --role/string

  /**
  Removes the user with $user-id from the organization with
    $organization-id.
  */
  organization-member-remove --organization-id/Uuid --user-id/Uuid

  /**
  Updates the role of the user with $user-id in the organization
    with $organization-id.
  */
  organization-member-set-role --organization-id/Uuid --user-id/Uuid --role/string

  /**
  Gets the profile of the user with the given ID.

  If no user ID is given, the profile of the current user is returned.
  Returns null, if no user with the given ID exists.
  */
  get-profile --user-id/Uuid?=null -> Map?

  /**
  Updates the profile of the current user.
  */
  // TODO(florian): add support for changing the email.
  update-profile --name/string

with-server server-config/ServerConfig --cli/Cli [block]:
  network := net.open
  server/ArtemisServerCli? := null
  try:
    server = ArtemisServerCli network server-config --cli=cli
    block.call server
  finally:
    if server: server.close
    network.close
