// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import encoding.ubjson
import http
import log
import net
import encoding.json
import encoding.base64

import ..artemis_server
import ...device
import ...organization

import ....shared.server_config

class ArtemisServerCliHttpToit implements ArtemisServerCli:
  client_/http.Client
  server_config_/ServerConfigHttpToit

  constructor network/net.Interface .server_config_/ServerConfigHttpToit:
    client_ = http.Client network

  is_closed -> bool:
    // TODO(florian): we need a newer http client to be able to
    // ask whether it's closed.
    return false

  close -> none:
    // TODO(florian): we need a newer http client to be able to close it.

  create_device_in_organization --organization_id/string --device_id/string -> Device:
    map := {
      "organization_id": organization_id,
    }
    if device_id != "": map["alias"] = device_id

    device_info := send_request_ "create-device-in-organization" map
    return Device
        --hardware_id=device_info["hardware_id"]
        --id=device_info["id"]
        --organization_id=device_info["organization_id"]

  notify_created --hardware_id/string -> none:
    send_request_ "notify-created" {
      "hardware_id": hardware_id,
      "data": { "type": "created" },
    }

  get_current_user_id -> string:
    return send_request_ "get-current-user-id" {:}

  get_organizations -> List:
    organizations := send_request_ "get-organizations" {:}
    return organizations.map: Organization.from_map it

  get_organization id -> DetailedOrganization?:
    organization := send_request_ "get-organization-details" {
      "id": id,
    }
    if organization == null: return null
    return DetailedOrganization.from_map organization

  create_organization name/string -> Organization:
    organization := send_request_ "create-organization" {
      "name": name,
    }
    return Organization.from_map organization

  get_organization_members id/string -> List:
    return send_request_ "get-organization-members" {
      "id": id,
    }

  organization_member_add --organization_id/string --user_id/string --role/string:
    send_request_ "organization-member-add" {
      "organization_id": organization_id,
      "user_id": user_id,
      "role": role,
    }

  organization_member_remove --organization_id/string --user_id/string:
    send_request_ "organization-member-remove" {
      "organization_id": organization_id,
      "user_id": user_id,
    }

  organization_member_set_role --organization_id/string --user_id/string --role/string:
    send_request_ "organization-member-set-role" {
      "organization_id": organization_id,
      "user_id": user_id,
      "role": role,
    }

  get_profile --user_id/string?=null -> Map?:
    return send_request_ "get-profile" {
      "id": user_id,
    }

  update_profile --name/string -> none:
    send_request_ "update-profile" {
      "name": name,
    }

  list_sdk_service_versions --sdk_version/string?=null --service_version/string?=null -> List:
    return send_request_ "list-sdk-service-versions" {
      "sdk_version": sdk_version,
      "service_version": service_version,
    }

  download_service_image image/string -> ByteArray:
    image64 := send_request_ "download-service-image" {
      "image": image,
    }
    return base64.decode image64

  send_request_ command/string data/Map -> any:
    encoded := ubjson.encode {
      "command": command,
      "data": data,
    }
    response := client_.post encoded
        --host=server_config_.host
        --port=server_config_.port
        --path="/"

    if response.status_code != 200:
      throw "HTTP error: $response.status_code $response.status_message"

    encoded_response := #[]
    while chunk := response.body.read:
      encoded_response += chunk
    decoded := ubjson.decode encoded_response
    if not (decoded.get "success"):
      throw "Broker error: $(decoded.get "error")"

    return decoded["data"]
