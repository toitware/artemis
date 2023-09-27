// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import http
import net
import encoding.json
import supabase
import supabase.filter show equals is-null orr
import uuid

import ..artemis-server
import ...config
import ...device
import ...organization
import ...ui

import ....shared.server-config

class ArtemisServerCliSupabase implements ArtemisServerCli:
  client_/supabase.Client? := ?
  server-config_/ServerConfigSupabase

  constructor network/net.Interface .server-config_/ServerConfigSupabase config/Config:
    local-storage := ConfigLocalStorage config --auth-key="$(CONFIG-SERVER-AUTHS-KEY).$(server-config_.name)"
    client_ = supabase.Client network --server-config=server-config_ --local-storage=local-storage
        --certificate-provider=: certificate-roots.MAP[it]

  is-closed -> bool:
    return client_ == null

  close:
    if not client_: return
    client_.close
    client_ = null

  ensure-authenticated [block]:
    client_.ensure-authenticated block

  sign-up --email/string --password/string:
    client_.auth.sign-up --email=email --password=password

  sign-in --email/string --password/string:
    client_.auth.sign-in --email=email --password=password

  sign-in --provider/string --ui/Ui --open-browser/bool:
    client_.auth.sign-in --provider=provider --ui=ui --open-browser=open-browser

  update --email/string? --password/string?:
    payload := {:}
    if email: payload["email"] = email
    if password: payload["password"] = password
    client_.auth.update-current-user payload

  create-device-in-organization --organization-id/uuid.Uuid --device-id/uuid.Uuid? -> Device:
    payload := {
      "organization_id": "$organization-id",
    }

    if device-id: payload["alias"] = "$device-id"

    inserted := client_.rest.insert "devices" payload
    return Device
        --hardware-id=uuid.parse inserted["id"]
        --id=uuid.parse inserted["alias"]
        --organization-id=uuid.parse inserted["organization_id"]

  notify-created --hardware-id/uuid.Uuid -> none:
    client_.rest.insert "events" --no-return-inserted {
      "device_id": "$hardware-id",
      "data": { "type": "created" }
    }

  get-current-user-id -> uuid.Uuid:
    return uuid.parse client_.auth.get-current-user["id"]

  get-organizations -> List:
    // TODO(florian): we only need the id and the name.
    organizations := client_.rest.select "organizations"
    return organizations.map: Organization.from-map it

  get-organization id/uuid.Uuid -> OrganizationDetailed?:
    organizations := client_.rest.select "organizations" --filters=[
      equals "id" "$id"
    ]
    if organizations.is-empty: return null
    return OrganizationDetailed.from-map organizations[0]

  create-organization name/string -> Organization:
    inserted := client_.rest.insert "organizations" { "name": name }
    return Organization.from-map inserted

  update-organization organization-id/uuid.Uuid --name/string -> none:
    update := {
      "name": name,
    }
    client_.rest.update "organizations" update --filters=[
      equals "id" "$organization-id"
    ]

  get-organization-members organization-id/uuid.Uuid -> List:
    members := client_.rest.select "roles" --filters=[
      equals "organization_id" "$organization-id"
    ]
    return members.map: {
      "id": uuid.parse it["user_id"],
      "role": it["role"],
    }

  organization-member-add --organization-id/uuid.Uuid --user-id/uuid.Uuid --role/string:
    client_.rest.insert "roles" {
      "organization_id": "$organization-id",
      "user_id": "$user-id",
      "role": role,
    }

  organization-member-remove --organization-id/uuid.Uuid --user-id/uuid.Uuid:
    client_.rest.delete "roles" --filters=[
      equals "organization_id" "$organization-id",
      equals "user_id" "$user-id",
    ]

  organization-member-set-role --organization-id/uuid.Uuid --user-id/uuid.Uuid --role/string:
    client_.rest.update "roles" --filters=[
      equals "organization_id" "$organization-id",
      equals "user_id" "$user-id",
    ] { "role": role }

  get-profile --user-id/uuid.Uuid?=null -> Map?:
    if not user-id:
      // TODO(florian): we should have the current user cached.
      current-user := client_.auth.get-current-user
      user-id = uuid.parse current-user["id"]
    response := client_.rest.select "profiles_with_email" --filters=[
      equals "id" "$user-id",
    ]
    if response.is-empty: return null
    result := response[0]
    result["id"] = uuid.parse result["id"]
    return result

  update-profile --name/string -> none:
    // TODO(florian): we should have the current user cached.
    current-user := client_.auth.get-current-user
    user-id := uuid.parse current-user["id"]
    client_.rest.update "profiles"  { "name": name } --filters=[
      equals "id" "$user-id",
    ]

  list-sdk-service-versions -> List
      --organization-id/uuid.Uuid
      --sdk-version/string?=null
      --service-version/string?=null:
    filters := [
      orr [
        is-null "organization_id",
        equals "organization_id" "$organization-id",
      ]
    ]
    if sdk-version: filters.add (equals "sdk_version" sdk-version)
    if service-version: filters.add (equals "service_version" service-version)
    return client_.rest.select "sdk_service_versions" --filters=filters

  download-service-image image/string -> ByteArray:
    return client_.storage.download --public --path="service-images/$image"
