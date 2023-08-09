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
import ....shared.constants show *

class ArtemisServerCliHttpToit implements ArtemisServerCli:
  client_/http.Client? := ?
  server_config_/ServerConfigHttp
  current_user_id_/uuid.Uuid? := null
  config_/Config

  constructor network/net.Interface .server_config_/ServerConfigHttp .config_/Config:
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
    send_request_ COMMAND_SIGN_UP_ {
      "email": email,
      "password": password,
    }

  sign_in --email/string --password/string:
    id := send_request_ COMMAND_SIGN_IN_ {
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

    device_info := send_request_ COMMAND_CREATE_DEVICE_IN_ORGANIZATION_ map
    return Device
        --hardware_id=uuid.parse device_info["id"]
        --id=uuid.parse device_info["alias"]
        --organization_id=uuid.parse device_info["organization_id"]

  notify_created --hardware_id/uuid.Uuid -> none:
    send_request_ COMMAND_NOTIFY_ARTEMIS_CREATED_ {
      "hardware_id": "$hardware_id",
      "data": { "type": "created" },
    }

  get_current_user_id -> uuid.Uuid:
    return current_user_id_

  get_organizations -> List:
    organizations := send_request_ COMMAND_GET_ORGANIZATIONS_ {:}
    return organizations.map: Organization.from_map it

  get_organization id/uuid.Uuid -> OrganizationDetailed?:
    organization := send_request_ COMMAND_GET_ORGANIZATION_DETAILS_ {
      "id": "$id",
    }
    if organization == null: return null
    return OrganizationDetailed.from_map organization

  create_organization name/string -> Organization:
    organization := send_request_ COMMAND_CREATE_ORGANIZATION_ {
      "name": name,
    }
    return Organization.from_map organization

  update_organization organization_id/uuid.Uuid --name/string -> none:
    update := {
      "name": name,
    }
    send_request_ COMMAND_UPDATE_ORGANIZATION_ {
      "id": "$organization_id",
      "update": update,
    }

  get_organization_members id/uuid.Uuid -> List:
    response := send_request_ COMMAND_GET_ORGANIZATION_MEMBERS_ {
      "id": "$id",
    }
    return response.map: {
      "id": uuid.parse it["id"],
      "role": it["role"],
    }

  organization_member_add --organization_id/uuid.Uuid --user_id/uuid.Uuid --role/string:
    send_request_ COMMAND_ORGANIZATION_MEMBER_ADD_ {
      "organization_id": "$organization_id",
      "user_id": "$user_id",
      "role": role,
    }

  organization_member_remove --organization_id/uuid.Uuid --user_id/uuid.Uuid:
    send_request_ COMMAND_ORGANIZATION_MEMBER_REMOVE_ {
      "organization_id": "$organization_id",
      "user_id": "$user_id",
    }

  organization_member_set_role --organization_id/uuid.Uuid --user_id/uuid.Uuid --role/string:
    send_request_ COMMAND_ORGANIZATION_MEMBER_SET_ROLE_ {
      "organization_id": "$organization_id",
      "user_id": "$user_id",
      "role": role,
    }

  get_profile --user_id/uuid.Uuid?=null -> Map?:
    result := send_request_ COMMAND_GET_PROFILE_ {
      "id": user_id ? "$user_id" : null,
    }
    if not result: return null
    result["id"] = uuid.parse result["id"]
    return result

  update_profile --name/string -> none:
    send_request_ COMMAND_UPDATE_PROFILE_ {
      "name": name,
    }

  list_sdk_service_versions -> List
      --organization_id/uuid.Uuid
      --sdk_version/string?=null
      --service_version/string?=null:
    return send_request_ COMMAND_LIST_SDK_SERVICE_VERSIONS_ {
      "organization_id": "$organization_id",
      "sdk_version": sdk_version,
      "service_version": service_version,
    }

  download_service_image image/string -> ByteArray:
    encoded_image := send_request_ COMMAND_DOWNLOAD_SERVICE_IMAGE_ {
      "image": image,
    }
    return base64.decode encoded_image

  send_request_ command/int data/Map -> any:
    encoded/ByteArray := #[command] + (json.encode data)
    headers := http.Headers
    if current_user_id_ != null:
      headers.add "X-User-Id" "$current_user_id_"

    if server_config_.admin_headers:
      server_config_.admin_headers.do: | key value |
        headers.add key value

    response := client_.post encoded
        --host=server_config_.host
        --port=server_config_.port
        --path="/"
        --headers=headers

    if response.status_code != http.STATUS_OK and response.status_code != http.STATUS_IM_A_TEAPOT:
      throw "HTTP error: $response.status_code $response.status_message"

    decoded := json.decode_stream response.body
    if response.status_code == http.STATUS_IM_A_TEAPOT:
      throw "Broker error: $decoded"
    return decoded
