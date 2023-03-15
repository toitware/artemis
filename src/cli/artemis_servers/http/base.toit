// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import encoding.ubjson
import http
import log
import net
import encoding.json
import encoding.base64

import ..artemis_server
import ...config
import ...device
import ...organization
import ...ui

import ....shared.server_config

STATUS_IM_A_TEAPOT ::= 418

class ArtemisServerCliHttpToit implements ArtemisServerCli:
  client_/http.Client? := ?
  server_config_/ServerConfigHttpToit
  current_user_id_/string? := null
  config_/Config

  constructor network/net.Interface .server_config_/ServerConfigHttpToit .config_/Config:
    client_ = http.Client network
    add_finalizer this:: close

  is_closed -> bool:
    return client_ == null

  close -> none:
    if not client_: return
    remove_finalizer this
    client_.close
    client_ = null

  ensure_authenticated [block]:
    if current_user_id_: return
    user_id := config_.get "$(CONFIG_SERVER_AUTHS_KEY).$(server_config_.name)"
    if user_id:
      current_user_id_ = user_id
      return
    block.call

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
    current_user_id_ = id
    config_["$(CONFIG_SERVER_AUTHS_KEY).$(server_config_.name)"] = id
    config_.write

  sign_in --provider/string --ui/Ui --open_browser/bool:
    throw "UNIMPLEMENTED"

  create_device_in_organization --organization_id/string --device_id/string -> Device:
    map := {
      "organization_id": organization_id,
    }
    if device_id != "": map["alias"] = device_id

    device_info := send_request_ "create-device-in-organization" map
    return Device
        --hardware_id=device_info["id"]
        --id=device_info["alias"]
        --organization_id=device_info["organization_id"]

  notify_created --hardware_id/string -> none:
    send_request_ "notify-created" {
      "hardware_id": hardware_id,
      "data": { "type": "created" },
    }

  get_current_user_id -> string:
    return current_user_id_

  get_organizations -> List:
    organizations := send_request_ "get-organizations" {:}
    return organizations.map: Organization.from_map it

  get_organization id -> OrganizationDetailed?:
    organization := send_request_ "get-organization-details" {
      "id": id,
    }
    if organization == null: return null
    return OrganizationDetailed.from_map organization

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
      payload["user_id"] = current_user_id_

    encoded := ubjson.encode payload
    response := client_.post encoded
        --host=server_config_.host
        --port=server_config_.port
        --path="/"

    if response.status_code != 200 and response.status_code != STATUS_IM_A_TEAPOT:
      throw "HTTP error: $response.status_code $response.status_message"

    // TODO(kasper): Use sized reader if possible.
    encoded_response := #[]
    while chunk := response.body.read:
      encoded_response += chunk

    decoded := ubjson.decode encoded_response
    if response.status_code == STATUS_IM_A_TEAPOT:
      throw "Broker error: $decoded"
    return decoded
