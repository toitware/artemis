// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import encoding.ubjson
import http
import log
import net
import encoding.json
import encoding.base64
import uuid

import ..artemis_server
import ...config
import ...device
import ...organization
import ...ui

import ....shared.server_config
import ....shared.utils as utils

STATUS_IM_A_TEAPOT ::= 418

class ArtemisServerCliHttpToit implements ArtemisServerCli:
  client_/http.Client? := ?
  server_config_/ServerConfigHttpToit
  current_user_id_/uuid.Uuid? := null
  config_/Config

  constructor network/net.Interface .server_config_/ServerConfigHttpToit .config_/Config:
    client_ = http.Client network

  is_closed -> bool:
    return client_ == null

  close -> none:
    if not client_: return
    client_.close
    client_ = null

  ensure_authenticated [block]:
    if current_user_id_: return
    user_id := config_.get "$(CONFIG_SERVER_AUTHS_KEY).$(server_config_.name)"
    if user_id:
      current_user_id_ = uuid.parse user_id
      return
    block.call "Not logged in"

  sign_up --email/string --password/string:
    send_request_ "sign-up" {
      "email": email,
      "password": password,
    }

  sign_in --email/string --password/string:
    id := send_request_ "sign-in" {
      "email": email,
      "password": password,
    }
    current_user_id_ = uuid.parse id
    config_["$(CONFIG_SERVER_AUTHS_KEY).$(server_config_.name)"] = id
    config_.write

  sign_in --provider/string --ui/Ui --open_browser/bool:
    throw "UNIMPLEMENTED"

  create_device_in_organization --organization_id/uuid.Uuid --device_id/uuid.Uuid? -> Device:
    map := {
      "organization_id": "$organization_id",
    }
    if device_id: map["alias"] = "$device_id"

    device_info := send_request_ "create-device-in-organization" map
    return Device
        --hardware_id=uuid.parse device_info["id"]
        --id=uuid.parse device_info["alias"]
        --organization_id=uuid.parse device_info["organization_id"]

  notify_created --hardware_id/uuid.Uuid -> none:
    send_request_ "notify-created" {
      "hardware_id": "$hardware_id",
      "data": { "type": "created" },
    }

  get_current_user_id -> uuid.Uuid:
    return current_user_id_

  get_organizations -> List:
    organizations := send_request_ "get-organizations" {:}
    return organizations.map: Organization.from_map it

  get_organization id/uuid.Uuid -> OrganizationDetailed?:
    organization := send_request_ "get-organization-details" {
      "id": "$id",
    }
    if organization == null: return null
    return OrganizationDetailed.from_map organization

  create_organization name/string -> Organization:
    organization := send_request_ "create-organization" {
      "name": name,
    }
    return Organization.from_map organization

  update_organization organization_id/uuid.Uuid --name/string -> none:
    update := {
      "name": name,
    }
    send_request_ "update-organization" {
      "id": "$organization_id",
      "update": update,
    }

  get_organization_members id/uuid.Uuid -> List:
    response := send_request_ "get-organization-members" {
      "id": "$id",
    }
    return response.map: {
      "id": uuid.parse it["id"],
      "role": it["role"],
    }

  organization_member_add --organization_id/uuid.Uuid --user_id/uuid.Uuid --role/string:
    send_request_ "organization-member-add" {
      "organization_id": "$organization_id",
      "user_id": "$user_id",
      "role": role,
    }

  organization_member_remove --organization_id/uuid.Uuid --user_id/uuid.Uuid:
    send_request_ "organization-member-remove" {
      "organization_id": "$organization_id",
      "user_id": "$user_id",
    }

  organization_member_set_role --organization_id/uuid.Uuid --user_id/uuid.Uuid --role/string:
    send_request_ "organization-member-set-role" {
      "organization_id": "$organization_id",
      "user_id": "$user_id",
      "role": role,
    }

  get_profile --user_id/uuid.Uuid?=null -> Map?:
    result := send_request_ "get-profile" {
      "id": user_id ? "$user_id" : null,
    }
    if not result: return null
    result["id"] = uuid.parse result["id"]
    return result

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
    encoded_image := send_request_ "download-service-image" {
      "image": image,
    }
    return base64.decode encoded_image

  send_request_ command/string data/Map -> any:
    payload := {
      "command": command,
      "data": data,
    }
    if current_user_id_ != null:
      payload["user_id"] = "$current_user_id_"

    encoded := ubjson.encode payload
    response := client_.post encoded
        --host=server_config_.host
        --port=server_config_.port
        --path="/"

    if response.status_code != http.STATUS_OK and response.status_code != STATUS_IM_A_TEAPOT:
      throw "HTTP error: $response.status_code $response.status_message"

    decoded := ubjson.decode (utils.read_all response.body)
    if response.status_code == STATUS_IM_A_TEAPOT:
      throw "Broker error: $decoded"
    return decoded
