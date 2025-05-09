// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate-roots
import cli show Cli
import http
import net
import encoding.json
import supabase
import supabase.filter show equals is-null orr
import uuid show Uuid

import ..artemis-server
import ...config
import ...device
import ...organization
import ...utils.supabase

import ....shared.server-config

TOIT_IO_AUTH_REDIRECT_URL ::= "https://toit.io/auth"

class ArtemisServerCliSupabase implements ArtemisServerCli:
  client_/supabase.Client? := ?
  server-config_/ServerConfigSupabase

  constructor network/net.Interface .server-config_/ServerConfigSupabase --cli/Cli:
    local-storage := ConfigLocalStorage --auth-key="$(CONFIG-SERVER-AUTHS-KEY).$(server-config_.name)" --cli=cli
    client_ = supabase.Client network --server-config=server-config_ --local-storage=local-storage

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

  sign-in --provider/string --open-browser/bool --cli/Cli:
    client_.auth.sign-in
        --provider=provider
        --open-browser=open-browser
        --redirect-url=TOIT_IO_AUTH_REDIRECT_URL
        --ui=SupabaseUi cli

  update --email/string? --password/string?:
    payload := {:}
    if email: payload["email"] = email
    if password: payload["password"] = password
    client_.auth.update-current-user payload

  logout:
    client_.auth.logout

  create-device-in-organization --organization-id/Uuid --device-id/Uuid? -> Device:
    payload := {
      "organization_id": "$organization-id",
    }

    if device-id: payload["alias"] = "$device-id"

    inserted := client_.rest.insert "devices" payload
    return Device
        --hardware-id=Uuid.parse inserted["id"]
        --id=Uuid.parse inserted["alias"]
        --organization-id=Uuid.parse inserted["organization_id"]

  notify-created --hardware-id/Uuid -> none:
    client_.rest.insert "events" --no-return-inserted {
      "device_id": "$hardware-id",
      "data": { "type": "created" }
    }

  get-current-user-id -> Uuid:
    return Uuid.parse client_.auth.get-current-user["id"]

  get-organizations -> List:
    // TODO(florian): we only need the id and the name.
    organizations := client_.rest.select "organizations"
    return organizations.map: Organization.from-map it

  get-organization id/Uuid -> OrganizationDetailed?:
    organizations := client_.rest.select "organizations" --filters=[
      equals "id" "$id"
    ]
    if organizations.is-empty: return null
    return OrganizationDetailed.from-map organizations[0]

  create-organization name/string -> Organization:
    inserted := client_.rest.insert "organizations" { "name": name }
    return Organization.from-map inserted

  update-organization organization-id/Uuid --name/string -> none:
    update := {
      "name": name,
    }
    client_.rest.update "organizations" update --filters=[
      equals "id" "$organization-id"
    ]

  get-organization-members organization-id/Uuid -> List:
    members := client_.rest.select "roles" --filters=[
      equals "organization_id" "$organization-id"
    ]
    return members.map: {
      "id": Uuid.parse it["user_id"],
      "role": it["role"],
    }

  organization-member-add --organization-id/Uuid --user-id/Uuid --role/string:
    client_.rest.insert "roles" {
      "organization_id": "$organization-id",
      "user_id": "$user-id",
      "role": role,
    }

  organization-member-remove --organization-id/Uuid --user-id/Uuid:
    client_.rest.delete "roles" --filters=[
      equals "organization_id" "$organization-id",
      equals "user_id" "$user-id",
    ]

  organization-member-set-role --organization-id/Uuid --user-id/Uuid --role/string:
    client_.rest.update "roles" --filters=[
      equals "organization_id" "$organization-id",
      equals "user_id" "$user-id",
    ] { "role": role }

  get-profile --user-id/Uuid?=null -> Map?:
    if not user-id:
      // TODO(florian): we should have the current user cached.
      current-user := client_.auth.get-current-user
      user-id = Uuid.parse current-user["id"]
    response := client_.rest.select "profiles_with_email" --filters=[
      equals "id" "$user-id",
    ]
    if response.is-empty: return null
    result := response[0]
    result["id"] = Uuid.parse result["id"]
    return result

  update-profile --name/string -> none:
    // TODO(florian): we should have the current user cached.
    current-user := client_.auth.get-current-user
    user-id := Uuid.parse current-user["id"]
    client_.rest.update "profiles"  { "name": name } --filters=[
      equals "id" "$user-id",
    ]
