// Copyright (C) 2022 Toitware ApS. All rights reserved.

import artemis.shared.constants show *
import cli
import uuid
import encoding.base64
import encoding.json

// This is a bit hackish, but we want to open-source the base and not
// copy it.
import .public.broker.base

main args:
  root-cmd := cli.Command "root"
    --help="""An HTTP-based Artemis server.

      Can be used instead of the Supabase servers.
      This server keeps data in memory and should thus only be used for testing.
      """
    --options=[
      cli.OptionInt "port" --short-name="p"
          --help="The port to listen on."
    ]
    --run=:: | parsed/cli.Parsed |
      broker := HttpArtemisServer parsed["port"]
      broker.start

  root-cmd.run args

class DeviceEntry:
  id/string
  alias/string
  organization-id/string

  constructor .id --.alias --.organization-id:

class EventEntry:
  device-id/string
  data/any

  constructor .device-id --.data:

  stringify -> string:
    return "EventEntry($device-id, $data)"

class OrganizationEntry:
  id/string
  name/string := ?
  created-at/Time
  members/Map := {:}

  constructor .id --.name --.created-at:

  to-json -> Map:
    return {
      "id": id,
      "name": name,
      "created_at": created-at.stringify,
    }

class User:
  id/string
  email/string := ?
  name/string := ?

  constructor .id --.email --.name:

  to-json -> Map:
    return {
      "id": id,
      "email": email,
      "name": name,
    }

class HttpArtemisServer extends HttpServer:
  static DEVICE-NOT-FOUND ::= 0

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

  sdk-service-versions := []
  image-binaries := {:}

  constructor port/int:
    super port

  run-command command/int encoded/ByteArray user-id/string? -> any:
    data := ?

    if command == COMMAND-UPLOAD-SERVICE-IMAGE_:
      meta-end := encoded.index-of '\0'
      meta := encoded[0..meta-end]
      content := encoded[meta-end + 1 ..]
      data = {
        "meta": meta,
        "content": content,
      }
    else:
      data = json.decode encoded

    print "$Time.now: Artemis request $(ARTEMIS-COMMAND-TO-STRING.get command) ($command) for $user-id with $data."
    if user-id and not users.contains user-id:
      throw "User not found: $user-id"

    if command == COMMAND-CHECK-IN_:
      return store-event data
    if command == COMMAND-CREATE-DEVICE-IN-ORGANIZATION_:
      return create-device-in-organization data
    if command == COMMAND-NOTIFY-ARTEMIS-CREATED_:
      return store-event data
    if command == COMMAND-SIGN-UP_:
      return sign-up data
    if command == COMMAND-SIGN-IN_:
      return sign-in data
    if command == COMMAND-UPDATE-CURRENT-USER_:
      return update-current-user data user-id
    if command == COMMAND-GET-ORGANIZATIONS_:
      return get-organizations data user-id
    if command == COMMAND-GET-ORGANIZATION-DETAILS_:
      return get-organization-details data user-id
    if command == COMMAND-CREATE-ORGANIZATION_:
      return create-organization data user-id
    if command == COMMAND-UPDATE-ORGANIZATION_:
      return update-organization data
    if command == COMMAND-GET-ORGANIZATION-MEMBERS_:
      return get-organization-members data
    if command == COMMAND-ORGANIZATION-MEMBER-ADD_:
      return organization-member-add data user-id
    if command == COMMAND-ORGANIZATION-MEMBER-REMOVE_:
      return organization-member-remove data
    if command == COMMAND-ORGANIZATION-MEMBER-SET-ROLE_:
      return organization-member-set-role data user-id
    if command == COMMAND-GET-PROFILE_:
      return get-profile data user-id
    if command == COMMAND-UPDATE-PROFILE_:
      return update-profile data user-id
    if command == COMMAND-LIST-SDK-SERVICE-VERSIONS_:
      return list-sdk-service-versions data user-id
    if command == COMMAND-DOWNLOAD-SERVICE-IMAGE_:
      return download-service-image data
    if command == COMMAND-UPLOAD-SERVICE-IMAGE_:
      return upload-service-image data

    else:
      throw "BAD COMMAND $command"

  store-event data/Map:
    device-id := data["hardware_id"]
    if not devices.contains device-id:
      errors.add [DEVICE-NOT-FOUND, device-id]
      throw "Device not found"
    events.add
        EventEntry device-id --data=data["data"]

  create-device-in-organization data/Map:
    organization-id := data["organization_id"]
    alias := data.get "alias"

    hardware-id := "$(uuid.uuid5 "" "hardware_id - $Time.monotonic-us")"
    alias-id := alias or "$(uuid.uuid5 "" "alias_id - $Time.monotonic-us")"

    devices.do: | key entry/DeviceEntry |
      if entry.alias == alias-id:
        throw "Alias already exists"

    devices[hardware-id] = DeviceEntry hardware-id
        --alias=alias-id
        --organization-id=organization-id
    return {
      "id": hardware-id,
      "alias": alias-id,
      "organization_id": organization-id,
    }

  remove-device hardware-id/string -> none:
    devices.remove hardware-id

  create-user --email/string --name/string --id/string?=null -> string:
    if not id: id = (uuid.uuid5 "" "user_id - $Time.monotonic-us").stringify
    user := User id --email=email --name=name
    users[id] = user
    return id

  get-organizations data/Map user-id/string? -> List:
    result := []
    if not user-id: return result
    organizations.do: | _ entry/OrganizationEntry |
      if entry.members.contains user-id:
        result.add {"id": entry.id, "name": entry.name}
    return result

  get-organization-details data/Map user-id/string? -> Map?:
    organization-id := data["id"]
    organization := organizations.get organization-id
    if not organization: return null
    if not user-id or not organization.members.contains user-id:
      throw "Not a member of this organization"
    return organization.to-json

  create-organization data/Map user-id/string? -> Map:
    if not user-id: throw "Not logged in"
    id := "$(uuid.uuid5 "" "organization_id - $Time.monotonic-us")"
    name := data["name"]
    organization := create-organization --id=id --name=name --admin-id=user-id
    return organization.to-json

  create-organization --id/string --name/string --admin-id/string -> OrganizationEntry:
    organization := OrganizationEntry id --name=name --created-at=Time.now
    organizations[id] = organization
    organization.members[admin-id] = "admin"
    organizations[id] = organization
    return organization

  update-organization data:
    organization := organizations.get data["id"]
    if not organization: throw "Organization not found"
    organization.name = data["update"]["name"]
    return null

  get-organization-members data/Map -> List:
    organization-id := data["id"]
    organization := organizations.get organization-id
    if not organization: throw "Organization not found"
    result := []
    organization.members.do: | user-id role |
      result.add {
        "id": user-id,
        "role": role,
      }
    return result

  organization-member-add data/Map authenticated-user-id/string?:
    organization-id := data["organization_id"]
    user-id := data["user_id"]
    role := data["role"]
    organization-member-add
        --organization-id=organization-id
        --user-id=user-id
        --authenticated-user-id=authenticated-user-id
        --role=role
    return null

  organization-member-add
      --authenticated-user-id/string?
      --organization-id/string
      --user-id/string
      --role/string
      --admin-check/bool=true:
    if not authenticated-user-id: throw "Not logged in"
    organization := organizations.get organization-id
    if not organization: throw "Organization not found"
    user := users.get user-id
    if not user: throw "User not found"
    if role != "member" and role != "admin":
      throw "Invalid role $role"
    if organization.members.contains user-id:
      throw "User already a member of organization"
    if admin-check and ((organization.members.get authenticated-user-id) != "admin"):
      throw "Not an admin"
    organization.members[user-id] = role

  organization-member-remove data/Map:
    organization-id := data["organization_id"]
    user-id := data["user_id"]

    organization-member-remove
        --organization-id=organization-id
        --user-id=user-id
    return null

  organization-member-remove
      --organization-id/string
      --user-id/string
      --admin-check/bool=true:
    organization := organizations.get organization-id
    if not organization: throw "Organization not found"
    user := users.get user-id
    if not user: throw "User not found"
    if not organization.members.contains user-id:
      throw "User not a member of organization"
    organization.members.remove user-id
    return null

  organization-member-set-role data/Map authenticated-user-id/string?:
    organization-id := data["organization_id"]
    user-id := data["user_id"]
    role := data["role"]
    organization-member-set-role
        --authenticated-user-id=authenticated-user-id
        --organization-id=organization-id
        --user-id=user-id
        --role=role

  organization-member-set-role
      --authenticated-user-id/string?
      --organization-id/string
      --user-id/string
      --role/string
      --admin-check/bool=true:
    organization := organizations.get organization-id
    if not organization: throw "Organization not found"
    user := users.get user-id
    if not user: throw "User not found"
    if role != "member" and role != "admin":
      throw "Invalid role $role"
    if not organization.members.contains user-id:
      throw "User not a member of organization"
    if not authenticated-user-id: throw "Not logged in"
    if admin-check and ((organization.members.get authenticated-user-id) != "admin"):
      throw "Not an admin"
    organization.members[user-id] = role

  get-profile data/Map authenticated-user-id/string? -> Map?:
    id/string? := data["id"]
    if not id:
      if not authenticated-user-id: throw "Not logged in"
      id = authenticated-user-id
    user := users.get id
    return user and user.to-json

  update-profile data/Map user-id/string?:
    if not user-id: throw "Not logged in"
    user := users.get user-id
    if not user: throw "User not found"
    if data.contains "name": user.name = data["name"]
    if data.contains "email": user.email = data["email"]

  list-sdk-service-versions data/Map user-id/string? -> List:
    sdk-version := data.get "sdk_version"
    service-version := data.get "service_version"
    organization-id := data.get "organization_id"

    // Only return matching versions.
    return sdk-service-versions.filter: | entry/Map |
      if sdk-version and entry["sdk_version"] != sdk-version:
        continue.filter false
      if service-version and entry["service_version"] != service-version:
        continue.filter false
      entry-org := entry.get "organization_id"
      if entry-org:
        // Only return the versions for the given organization.
        if entry-org != organization-id: continue.filter false
        // But also check that the user is a member of the organization.
        if not user-id: continue.filter false
        organization := organizations.get entry["organization_id"]
        if not organization: continue.filter false
        if not organization.members.contains user-id: continue.filter false
      true
    return sdk-service-versions

  upload-service-image data/Map:
    meta := json.decode data["meta"]
    content := data["content"]
    sdk-version := meta["sdk_version"]
    service-version := meta["service_version"]
    image-id := meta["image_id"]
    organization-id := meta.get "organization_id"
    force := meta.get "force"

    image-binaries[image-id] = content
    // Update any existing entry if there is already one.
    sdk-service-versions.do: | entry/Map |
      if entry["sdk_version"] == sdk-version and entry["service_version"] == service-version:
        if not force:
          throw "Service version already exists"

        entry["image"] = image-id
        if organization-id:
          entry["organization_id"] = organization-id
        return
    new-entry := {
      "sdk_version": sdk-version,
      "service_version": service-version,
      "image": image-id,
    }
    if organization-id:
      new-entry["organization_id"] = organization-id
    sdk-service-versions.add new-entry

  download-service-image data/Map -> BinaryResponse:
    image-id := data["image"]
    image-bin := image-binaries.get image-id
    return BinaryResponse image-bin image-bin.size

  sign-up data/Map:
    email := data["email"]
    password := data["password"]
    if not email or not password:
      throw "Missing email, password"
    users.do: | _ user/User |
      if user.email == email:
        // We allow users to sign up multiple times with the same email address.
        return
    user-id := create-user --email=email --name=email

  sign-in data/Map:
    email := data["email"]
    password := data["password"]
    if not email or not password:
      throw "Missing email, password"
    users.do: | _ user/User |
      if user.email == email:
        return user.id
    throw "Invalid email or password"

  update-current-user data/Map user-id/string?:
    if not user-id: throw "Not logged in"
    email := data.get "email"
    password := data.get "pasword"
    if not email and not password:
      throw "Missing email, password"
    user := users.get user-id
    if not user: throw "User not found"
    if email: user.email = email
    if password: user.password = password
