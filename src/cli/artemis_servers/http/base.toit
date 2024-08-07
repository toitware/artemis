// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import cli show Cli
import encoding.ubjson
import http
import log
import net
import encoding.json
import encoding.base64
import uuid

import ..artemis-server
import ...config
import ...device
import ...organization

import ....shared.server-config
import ....shared.utils as utils
import ....shared.constants show *

class ArtemisServerCliHttpToit implements ArtemisServerCli:
  client_/http.Client? := ?
  server-config_/ServerConfigHttp
  current-user-id_/uuid.Uuid? := null
  cli_/Cli

  constructor network/net.Interface .server-config_/ServerConfigHttp --cli/Cli:
    client_ = http.Client network
    cli_ = cli

  is-closed -> bool:
    return client_ == null

  close -> none:
    if not client_: return
    client_.close
    client_ = null

  ensure-authenticated [block]:
    if current-user-id_: return
    user-id := cli_.config.get "$(CONFIG-SERVER-AUTHS-KEY).$(server-config_.name)"
    if user-id:
      current-user-id_ = uuid.parse user-id
      return
    block.call "Not logged in"

  sign-up --email/string --password/string:
    send-request_ COMMAND-SIGN-UP_ {
      "email": email,
      "password": password,
    }

  sign-in --email/string --password/string:
    id := send-request_ COMMAND-SIGN-IN_ {
      "email": email,
      "password": password,
    }
    current-user-id_ = uuid.parse id
    cli_.config["$(CONFIG-SERVER-AUTHS-KEY).$(server-config_.name)"] = id
    cli_.config.write

  sign-in --provider/string --open-browser/bool --cli/Cli:
    throw "UNIMPLEMENTED"

  update --email/string? --password/string?:
    payload := {:}
    if email: payload["email"] = email
    if password: payload["password"] = password
    send-request_ COMMAND-UPDATE-CURRENT-USER_ payload

  logout:
    if not current-user-id_: throw "Not logged in"
    current-user-id_ = null
    cli_.config.remove "$(CONFIG-SERVER-AUTHS-KEY).$(server-config_.name)"
    cli_.config.write

  create-device-in-organization --organization-id/uuid.Uuid --device-id/uuid.Uuid? -> Device:
    map := {
      "organization_id": "$organization-id",
    }
    if device-id: map["alias"] = "$device-id"

    device-info := send-request_ COMMAND-CREATE-DEVICE-IN-ORGANIZATION_ map
    return Device
        --hardware-id=uuid.parse device-info["id"]
        --id=uuid.parse device-info["alias"]
        --organization-id=uuid.parse device-info["organization_id"]

  notify-created --hardware-id/uuid.Uuid -> none:
    send-request_ COMMAND-NOTIFY-ARTEMIS-CREATED_ {
      "hardware_id": "$hardware-id",
      "data": { "type": "created" },
    }

  get-current-user-id -> uuid.Uuid:
    return current-user-id_

  get-organizations -> List:
    organizations := send-request_ COMMAND-GET-ORGANIZATIONS_ {:}
    return organizations.map: Organization.from-map it

  get-organization id/uuid.Uuid -> OrganizationDetailed?:
    organization := send-request_ COMMAND-GET-ORGANIZATION-DETAILS_ {
      "id": "$id",
    }
    if organization == null: return null
    return OrganizationDetailed.from-map organization

  create-organization name/string -> Organization:
    organization := send-request_ COMMAND-CREATE-ORGANIZATION_ {
      "name": name,
    }
    return Organization.from-map organization

  update-organization organization-id/uuid.Uuid --name/string -> none:
    update := {
      "name": name,
    }
    send-request_ COMMAND-UPDATE-ORGANIZATION_ {
      "id": "$organization-id",
      "update": update,
    }

  get-organization-members id/uuid.Uuid -> List:
    response := send-request_ COMMAND-GET-ORGANIZATION-MEMBERS_ {
      "id": "$id",
    }
    return response.map: {
      "id": uuid.parse it["id"],
      "role": it["role"],
    }

  organization-member-add --organization-id/uuid.Uuid --user-id/uuid.Uuid --role/string:
    send-request_ COMMAND-ORGANIZATION-MEMBER-ADD_ {
      "organization_id": "$organization-id",
      "user_id": "$user-id",
      "role": role,
    }

  organization-member-remove --organization-id/uuid.Uuid --user-id/uuid.Uuid:
    send-request_ COMMAND-ORGANIZATION-MEMBER-REMOVE_ {
      "organization_id": "$organization-id",
      "user_id": "$user-id",
    }

  organization-member-set-role --organization-id/uuid.Uuid --user-id/uuid.Uuid --role/string:
    send-request_ COMMAND-ORGANIZATION-MEMBER-SET-ROLE_ {
      "organization_id": "$organization-id",
      "user_id": "$user-id",
      "role": role,
    }

  get-profile --user-id/uuid.Uuid?=null -> Map?:
    result := send-request_ COMMAND-GET-PROFILE_ {
      "id": user-id ? "$user-id" : null,
    }
    if not result: return null
    result["id"] = uuid.parse result["id"]
    return result

  update-profile --name/string -> none:
    send-request_ COMMAND-UPDATE-PROFILE_ {
      "name": name,
    }

  list-sdk-service-versions -> List
      --organization-id/uuid.Uuid
      --sdk-version/string?=null
      --service-version/string?=null:
    return send-request_ COMMAND-LIST-SDK-SERVICE-VERSIONS_ {
      "organization_id": "$organization-id",
      "sdk_version": sdk-version,
      "service_version": service-version,
    }

  download-service-image image/string -> ByteArray:
    return send-request_ COMMAND-DOWNLOAD-SERVICE-IMAGE_ {
      "image": image,
    }

  send-request_ command/int data/Map -> any:
    encoded/ByteArray := #[command] + (json.encode data)
    headers := http.Headers
    if current-user-id_ != null:
      headers.add "X-User-Id" "$current-user-id_"

    if server-config_.admin-headers:
      server-config_.admin-headers.do: | key value |
        headers.add key value

    response := client_.post encoded
        --host=server-config_.host
        --port=server-config_.port
        --path="/"
        --headers=headers

    if response.status-code != http.STATUS-OK and response.status-code != http.STATUS-IM-A-TEAPOT:
      throw "HTTP error: $response.status-code $response.status-message"

    if (command == COMMAND-DOWNLOAD-SERVICE-IMAGE_)
        and response.status-code != http.STATUS-IM-A-TEAPOT:
      return utils.read-all response.body

    decoded := json.decode-stream response.body
    if response.status-code == http.STATUS-IM-A-TEAPOT:
      throw "Broker error: $decoded"
    return decoded
