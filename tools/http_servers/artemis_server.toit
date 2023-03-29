// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import uuid
import encoding.base64

import .base

main args:
  root_cmd := cli.Command "root"
    --long_help="""An HTTP-based Artemis server.

      Can be used instead of the Supabase servers.
      This server keeps data in memory and should thus only be used for testing.
      """
    --options=[
      cli.OptionInt "port" --short_name="p"
          --short_help="The port to listen on."
    ]
    --run=:: | parsed/cli.Parsed |
      broker := HttpArtemisServer parsed["port"]
      broker.start

  root_cmd.run args

class DeviceEntry:
  id/string
  alias/string
  organization_id/string

  constructor .id --.alias --.organization_id:

class EventEntry:
  device_id/string
  data/any

  constructor .device_id --.data:

  stringify -> string:
    return "EventEntry($device_id, $data)"

class OrganizationEntry:
  id/string
  name/string
  created_at/Time
  members/Map := {:}

  constructor .id --.name --.created_at:

  to_json -> Map:
    return {
      "id": id,
      "name": name,
      "created_at": created_at.stringify,
    }

class User:
  id/string
  email/string := ?
  name/string := ?

  constructor .id --.email --.name:

  to_json -> Map:
    return {
      "id": id,
      "email": email,
      "name": name,
    }

class HttpArtemisServer extends HttpServer:
  static DEVICE_NOT_FOUND ::= 0

  /** Map from ID to $OrganizationEntry. */
  organizations/Map := {:}
  /** Map from fleet-ID to organization ID. */
  fleets/Map := {:}
  /** Map from device-ID to $DeviceEntry. */
  devices/Map := {:}
  /** List of $EventEntry. */
  events/List := []

  /** Map from ID to $User. */
  users/Map := {:}

  errors/List := []

  sdk_service_versions := []
  image_binaries := {:}

  constructor port/int:
    super port

  run_command command/string data user_id/string? -> any:
    print "Request $command for $user_id"
    if user_id and not users.contains user_id:
      throw "User not found: $user_id"

    if command == "check-in": return store_event data
    if command == "create-device-in-organization":
      return create_device_in_organization data
    if command == "notify-created": return store_event data
    if command == "sign-up": return sign_up data
    if command == "sign-in": return sign_in data
    if command == "get-organizations":
      return get_organizations data user_id
    if command == "get-organization-details":
      return get_organization_details data user_id
    if command == "create-organization":
      return create_organization data user_id
    if command == "get-organization-members":
      return get_organization_members data
    if command == "organization-member-add":
      return organization_member_add data user_id
    if command == "organization-member-remove":
      return organization_member_remove data
    if command == "organization-member-set-role":
      return organization_member_set_role data user_id
    if command == "get-profile":
      return get_profile data user_id
    if command == "update-profile":
      return update_profile data user_id
    if command == "list-sdk-service-versions":
      return list_sdk_service_versions data user_id
    if command == "download-service-image":
      return download_service_image data
    if command == "upload-service-image":
      return upload_service_image data

    else:
      throw "BAD COMMAND $command"

  store_event data/Map:
    device_id := data["hardware_id"]
    if not devices.contains device_id:
      errors.add [DEVICE_NOT_FOUND, device_id]
      throw "Device not found"
    events.add
        EventEntry device_id --data=data["data"]

  create_device_in_organization data/Map:
    organization_id := data["organization_id"]
    alias := data.get "alias"

    hardware_id := "$(uuid.uuid5 "" "hardware_id - $Time.monotonic_us")"
    alias_id := alias or "$(uuid.uuid5 "" "alias_id - $Time.monotonic_us")"
    devices[hardware_id] = DeviceEntry hardware_id
        --alias=alias_id
        --organization_id=organization_id
    return {
      "id": hardware_id,
      "alias": alias_id,
      "organization_id": organization_id,
    }

  remove_device hardware_id/string -> none:
    devices.remove hardware_id

  create_user --email/string --name/string --id/string?=null -> string:
    if not id: id = (uuid.uuid5 "" "user_id - $Time.monotonic_us").stringify
    user := User id --email=email --name=name
    users[id] = user
    return id

  get_organizations data/Map user_id/string? -> List:
    result := []
    if not user_id: return result
    organizations.do: | _ entry/OrganizationEntry |
      if entry.members.contains user_id:
        result.add {"id": entry.id, "name": entry.name}
    return result

  get_organization_details data/Map user_id/string? -> Map?:
    organization_id := data["id"]
    organization := organizations.get organization_id
    if not organization: return null
    if not user_id or not organization.members.contains user_id:
      throw "Not a member of this organization"
    return organization.to_json

  create_organization data/Map user_id/string? -> Map:
    if not user_id: throw "Not logged in"
    id := "$(uuid.uuid5 "" "organization_id - $Time.monotonic_us")"
    name := data["name"]
    organization := create_organization --id=id --name=name --admin_id=user_id
    return organization.to_json

  create_organization --id/string --name/string --admin_id/string -> OrganizationEntry:
    organization := OrganizationEntry id --name=name --created_at=Time.now
    organizations[id] = organization
    organization.members[admin_id] = "admin"
    organizations[id] = organization
    return organization

  get_organization_members data/Map -> List:
    organization_id := data["id"]
    organization := organizations.get organization_id
    if not organization: throw "Organization not found"
    result := []
    organization.members.do: | user_id role |
      result.add {
        "id": user_id,
        "role": role,
      }
    return result

  organization_member_add data/Map authenticated_user_id/string?:
    organization_id := data["organization_id"]
    user_id := data["user_id"]
    role := data["role"]
    organization_member_add
        --organization_id=organization_id
        --user_id=user_id
        --authenticated_user_id=authenticated_user_id
        --role=role
    return null

  organization_member_add
      --authenticated_user_id/string?
      --organization_id/string
      --user_id/string
      --role/string
      --admin_check/bool=true:
    if not authenticated_user_id: throw "Not logged in"
    organization := organizations.get organization_id
    if not organization: throw "Organization not found"
    user := users.get user_id
    if not user: throw "User not found"
    if role != "member" and role != "admin":
      throw "Invalid role $role"
    if organization.members.contains user_id:
      throw "User already a member of organization"
    if admin_check and ((organization.members.get authenticated_user_id) != "admin"):
      throw "Not an admin"
    organization.members[user_id] = role

  organization_member_remove data/Map:
    organization_id := data["organization_id"]
    user_id := data["user_id"]

    organization_member_remove
        --organization_id=organization_id
        --user_id=user_id
    return null

  organization_member_remove
      --organization_id/string
      --user_id/string
      --admin_check/bool=true:
    organization := organizations.get organization_id
    if not organization: throw "Organization not found"
    user := users.get user_id
    if not user: throw "User not found"
    if not organization.members.contains user_id:
      throw "User not a member of organization"
    organization.members.remove user_id
    return null

  organization_member_set_role data/Map authenticated_user_id/string?:
    organization_id := data["organization_id"]
    user_id := data["user_id"]
    role := data["role"]
    organization_member_set_role
        --authenticated_user_id=authenticated_user_id
        --organization_id=organization_id
        --user_id=user_id
        --role=role

  organization_member_set_role
      --authenticated_user_id/string?
      --organization_id/string
      --user_id/string
      --role/string
      --admin_check/bool=true:
    organization := organizations.get organization_id
    if not organization: throw "Organization not found"
    user := users.get user_id
    if not user: throw "User not found"
    if role != "member" and role != "admin":
      throw "Invalid role $role"
    if not organization.members.contains user_id:
      throw "User not a member of organization"
    if not authenticated_user_id: throw "Not logged in"
    if admin_check and ((organization.members.get authenticated_user_id) != "admin"):
      throw "Not an admin"
    organization.members[user_id] = role

  get_profile data/Map authenticated_user_id/string? -> Map?:
    id/string? := data["id"]
    if not id:
      if not authenticated_user_id: throw "Not logged in"
      id = authenticated_user_id
    user := users.get id
    return user and user.to_json

  update_profile data/Map user_id/string?:
    if not user_id: throw "Not logged in"
    user := users.get user_id
    if not user: throw "User not found"
    if data.contains "name": user.name = data["name"]
    if data.contains "email": user.email = data["email"]

  list_sdk_service_versions data/Map user_id/string? -> List:
    sdk_version := data.get "sdk_version"
    service_version := data.get "service_version"

    // Only return matching versions.
    return sdk_service_versions.filter: | entry/Map |
      if sdk_version and entry["sdk_version"] != sdk_version:
        continue.filter false
      if service_version and entry["service_version"] != service_version:
        continue.filter false
      if entry.get "organization_id":
        if not user_id: continue.filter false
        organization := organizations.get entry["organization_id"]
        if not organization: continue.filter false
        if not organization.members.contains user_id: continue.filter false
      true
    return sdk_service_versions

  upload_service_image data/Map:
    sdk_version := data["sdk_version"]
    service_version := data["service_version"]
    image_id := data["image_id"]
    organization_id := data.get "organization_id"
    force := data.get "force"

    image_binaries[image_id] = base64.decode data["image_content"]
    // Update any existing entry if there is already one.
    sdk_service_versions.do: | entry/Map |
      if entry["sdk_version"] == sdk_version and entry["service_version"] == service_version:
        if not force:
          throw "Service version already exists"

        entry["image"] = image_id
        if organization_id:
          entry["organization_id"] = organization_id
        return
    new_entry := {
      "sdk_version": sdk_version,
      "service_version": service_version,
      "image": image_id,
    }
    if organization_id:
      new_entry["organization_id"] = organization_id
    sdk_service_versions.add new_entry

  download_service_image data/Map -> string:
    image := data["image"]
    return base64.encode image_binaries[image]

  sign_up data/Map:
    email := data["email"]
    password := data["password"]
    if not email or not password:
      throw "Missing email, password"
    users.do: | _ user/User |
      if user.email == email:
        // We allow users to sign up multiple times with the same email address.
        return
    user_id := create_user --email=email --name=email

  sign_in data/Map:
    email := data["email"]
    password := data["password"]
    if not email or not password:
      throw "Missing email, password"
    users.do: | _ user/User |
      if user.email == email:
        return user.id
    throw "Invalid email or password"
