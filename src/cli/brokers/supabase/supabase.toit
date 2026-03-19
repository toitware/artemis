// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show Cli
import http
import supabase
import supabase.filter show equals
import certificate-roots
import uuid show Uuid

import ..broker show AdminBrokerCli
import ..http.base
import ...config
import ...device
import ...organization
import ...utils.supabase
import ....shared.server-config

create-broker-cli-supabase-http server-config/ServerConfigSupabase --cli/Cli -> BrokerCliSupabase:
  local-storage := ConfigLocalStorage --cli=cli --auth-key="$(CONFIG-SERVER-AUTHS-KEY).$(server-config.name)"
  supabase-client := supabase.Client --server-config=server-config --local-storage=local-storage
  id := "supabase/$server-config.host"

  host-port := server-config.host

  host := host-port
  port := null
  colon-pos := host-port.index-of ":"
  if colon-pos >= 0:
    host = host-port[..colon-pos]
    port = int.parse host-port[colon-pos + 1..]

  http-config := ServerConfigHttp
      server-config.name
      --host=host
      --port=port
      --path="/functions/v1/b"
      --admin-headers=null
      --device-headers=null
      --use-tls=server-config.use-tls
      --root-certificate-ders=server-config.root-certificate-der ? [server-config.root-certificate-der] : null
      --poll-interval=server-config.poll-interval

  return BrokerCliSupabase --id=id supabase-client http-config


class BrokerCliSupabase extends BrokerCliHttp implements AdminBrokerCli:
  supabase-client_/supabase.Client? := null

  constructor --id/string .supabase-client_ http-config/ServerConfigHttp:
    super --id=id http-config

  ensure-authenticated [block]:
    supabase-client_.ensure-authenticated block

  sign-up --email/string --password/string:
    supabase-client_.auth.sign-up --email=email --password=password

  sign-in --email/string --password/string:
    supabase-client_.auth.sign-in --email=email --password=password

  sign-in --provider/string --cli/Cli --open-browser/bool:
    supabase-client_.auth.sign-in
        --provider=provider
        --open-browser=open-browser
        --ui=SupabaseUi cli

  update --email/string? --password/string?:
    payload := {:}
    if email: payload["email"] = email
    if password: payload["password"] = password
    supabase-client_.auth.update-current-user payload

  logout:
    supabase-client_.auth.logout

  extra-headers -> Map:
    bearer/string := supabase-client_.session_
        ? supabase-client_.session_.access-token
        : supabase-client_.anon_
    return {
      "Authorization": "Bearer $bearer",
    }

  // AdminBrokerCli implementation.

  get-current-user-id -> Uuid:
    return Uuid.parse supabase-client_.auth.get-current-user["id"]

  get-organizations -> List:
    organizations := supabase-client_.rest.select "organizations"
    return organizations.map: Organization.from-map it

  get-organization id/Uuid -> OrganizationDetailed?:
    organizations := supabase-client_.rest.select "organizations" --filters=[
      equals "id" "$id"
    ]
    if organizations.is-empty: return null
    return OrganizationDetailed.from-map organizations[0]

  create-organization name/string -> Organization:
    inserted := supabase-client_.rest.insert "organizations" { "name": name }
    return Organization.from-map inserted

  update-organization organization-id/Uuid --name/string -> none:
    update := {
      "name": name,
    }
    supabase-client_.rest.update "organizations" update --filters=[
      equals "id" "$organization-id"
    ]

  get-organization-members organization-id/Uuid -> List:
    members := supabase-client_.rest.select "roles" --filters=[
      equals "organization_id" "$organization-id"
    ]
    return members.map: {
      "id": Uuid.parse it["user_id"],
      "role": it["role"],
    }

  organization-member-add --organization-id/Uuid --user-id/Uuid --role/string:
    supabase-client_.rest.insert "roles" {
      "organization_id": "$organization-id",
      "user_id": "$user-id",
      "role": role,
    }

  organization-member-remove --organization-id/Uuid --user-id/Uuid:
    supabase-client_.rest.delete "roles" --filters=[
      equals "organization_id" "$organization-id",
      equals "user_id" "$user-id",
    ]

  organization-member-set-role --organization-id/Uuid --user-id/Uuid --role/string:
    supabase-client_.rest.update "roles" --filters=[
      equals "organization_id" "$organization-id",
      equals "user_id" "$user-id",
    ] { "role": role }

  get-profile --user-id/Uuid?=null -> Map?:
    if not user-id:
      current-user := supabase-client_.auth.get-current-user
      user-id = Uuid.parse current-user["id"]
    response := supabase-client_.rest.select "profiles_with_email" --filters=[
      equals "id" "$user-id",
    ]
    if response.is-empty: return null
    result := response[0]
    result["id"] = Uuid.parse result["id"]
    return result

  update-profile --name/string -> none:
    current-user := supabase-client_.auth.get-current-user
    user-id := Uuid.parse current-user["id"]
    supabase-client_.rest.update "profiles" { "name": name } --filters=[
      equals "id" "$user-id",
    ]

  create-device-in-organization --organization-id/Uuid --device-id/Uuid? -> Device:
    payload := {
      "organization_id": "$organization-id",
    }
    if device-id: payload["alias"] = "$device-id"
    inserted := supabase-client_.rest.insert "devices" payload
    return Device
        --hardware-id=Uuid.parse inserted["id"]
        --id=Uuid.parse inserted["alias"]
        --organization-id=Uuid.parse inserted["organization_id"]
