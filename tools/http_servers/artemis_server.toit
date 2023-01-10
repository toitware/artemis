// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli
import uuid

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

  current_user/string? := null

  constructor port/int:
    super port

  run_command command/string data -> any:
    if command == "check-in": return store_event data
    if command == "create-device-in-organization":
      return create_device_in_organization data
    if command == "notify-created": return store_event data
    if command == "get-organizations":
      result := []
      organizations.do: | _ entry/OrganizationEntry |
        result.add {"id": entry.id, "name": entry.name}
      return result
    if command == "get-organization-details":
      organization_id := data["id"]
      organization := organizations.get organization_id
      return organization and organization.to_json
    if command == "create-organization":
      id := "$(uuid.uuid5 "" "organization_id - $Time.monotonic_us")"
      organization := add_organization id data["name"]
      organizations[id] = organization
      return organization.to_json
    if command == "get-profile":
      return get_profile (data.get "id")
    if command == "update-profile":
      return update_profile data

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
    device_id := alias or "$(uuid.uuid5 "" "device_id - $Time.monotonic_us")"
    devices[hardware_id] = DeviceEntry hardware_id
        --alias=device_id
        --organization_id=organization_id
    return {
      "hardware_id": hardware_id,
      "id": device_id,
      "organization_id": organization_id,
    }

  add_organization id/string name/string -> OrganizationEntry:
    organization := OrganizationEntry id --name=name --created_at=Time.now
    organizations[id] = organization
    return organization

  create_user --email/string --name/string --id/string?=null
      --set_current/bool=false -> string:
    if not id: id = (uuid.uuid5 "" "user_id - $Time.monotonic_us").stringify
    if set_current: current_user = id
    user := User id --email=email --name=name
    users[id] = user
    return id

  set_current_user id/string:
    current_user = id

  get_profile id/string? -> Map?:
    if not id:
      if not current_user: throw "Not logged in"
      id = current_user
    user := users.get id
    return user and user.to_json

  update_profile data/Map:
    if not current_user: throw "Not logged in"
    user := users.get current_user
    if not user: throw "User not found"
    if data.contains "name": user.name = data["name"]
    if data.contains "email": user.email = data["email"]
