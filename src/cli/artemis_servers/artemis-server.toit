// Copyright (C) 2022 Toitware ApS. All rights reserved.

import log
import net
import uuid

import .supabase show ArtemisServerCliSupabase
import .http.base show ArtemisServerCliHttpToit
import ...shared.server-config
import ..auth
import ..config
import ..device
import ..organization
import ..ui

/**
An abstraction for the Artemis server.
*/
interface ArtemisServerCli implements Authenticatable:
  constructor network/net.Interface server-config/ServerConfig config/Config:
    if server-config is ServerConfigSupabase:
      return ArtemisServerCliSupabase network (server-config as ServerConfigSupabase) config
    if server-config is ServerConfigHttp:
      return ArtemisServerCliHttpToit network (server-config as ServerConfigHttp) config
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
  sign-in --provider/string --ui/Ui --open-browser/bool

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
  create-device-in-organization --organization-id/uuid.Uuid --device-id/uuid.Uuid? -> Device

  /**
  Notifies the server that the device with the given $hardware-id was created.

  This operation is mostly for debugging purposes, as the $create-device-in-organization
    already has a similar effect.
  */
  notify-created --hardware-id/uuid.Uuid

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
  get-organization id/uuid.Uuid -> OrganizationDetailed?

  /** Creates a new organization with the given $name. */
  create-organization name/string -> Organization

  /**
  Updates the given organization.
  */
  update-organization organization-id/uuid.Uuid --name/string -> none

  /**
  Gets a list of members.

  Each entry is a map consisting of the "id" and "role".
  */
  get-organization-members organization-id/uuid.Uuid -> List

  /**
  Adds the user with $user-id as a new member to the organization
    with $organization-id.
  */
  organization-member-add --organization-id/uuid.Uuid --user-id/uuid.Uuid --role/string

  /**
  Removes the user with $user-id from the organization with
    $organization-id.
  */
  organization-member-remove --organization-id/uuid.Uuid --user-id/uuid.Uuid

  /**
  Updates the role of the user with $user-id in the organization
    with $organization-id.
  */
  organization-member-set-role --organization-id/uuid.Uuid --user-id/uuid.Uuid --role/string

  /**
  Gets the profile of the user with the given ID.

  If no user ID is given, the profile of the current user is returned.
  Returns null, if no user with the given ID exists.
  */
  get-profile --user-id/uuid.Uuid?=null -> Map?

  /**
  Updates the profile of the current user.
  */
  // TODO(florian): add support for changing the email.
  update-profile --name/string

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
      --organization-id/uuid.Uuid
      --sdk-version/string?=null
      --service-version/string?=null

  /**
  Downloads the given $image.

  The $image must be a valid image name, as returned by
    $list-sdk-service-versions.
  */
  download-service-image image/string -> ByteArray

with-server server-config/ServerConfig config/Config [block]:
  network := net.open
  server/ArtemisServerCli? := null
  try:
    server = ArtemisServerCli network server-config config
    block.call server
  finally:
    if server: server.close
    network.close
