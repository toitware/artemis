// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import http
import net
import encoding.json
import supabase

import ..artemis_server
import ...config
import ...device
import ...organization

import ....shared.server_config

class ArtemisServerCliSupabase implements ArtemisServerCli:
  client_/supabase.Client? := ?
  server_config_/ServerConfigSupabase

  constructor network/net.Interface .server_config_/ServerConfigSupabase config/Config:
    local_storage := ConfigLocalStorage config --auth_key="$(CONFIG_SERVER_AUTHS_KEY).$(server_config_.name)"
    client_ = supabase.Client network --server_config=server_config_ --local_storage=local_storage
        --certificate_provider=: certificate_roots.MAP[it]

  close:
    if client_:
      client_.close
      client_ = null

  is_closed -> bool:
    return client_ == null

  create_device_in_organization --organization_id/string --device_id/string -> Device:
    payload := {
      "organization_id": organization_id,
    }
    if device_id != "": payload["alias"] = device_id

    inserted := client_.rest.insert "devices" payload
    return Device
        --hardware_id=inserted["id"]
        --id=inserted["alias"]
        --organization_id=inserted["organization_id"]

  notify_created --hardware_id/string -> none:
    client_.rest.insert "events" --no-return_inserted {
      "device_id": hardware_id,
      "data": { "type": "created" }
    }

  get_current_user_id -> string:
    return client_.auth.get_current_user["id"]

  get_organizations -> List:
    // TODO(florian): we only need the id and the name.
    organizations := client_.rest.select "organizations"
    return organizations.map: Organization.from_map it

  get_organization id/string -> DetailedOrganization?:
    organizations := client_.rest.select "organizations" --filters=[
      "id=eq.$id"
    ]
    if organizations.is_empty: return null
    return DetailedOrganization.from_map organizations[0]

  create_organization name/string -> Organization:
    inserted := client_.rest.insert "organizations" { "name": name }
    return Organization.from_map inserted

  get_organization_members id/string -> List:
    members := client_.rest.select "roles" --filters=[
      "organization_id=eq.$id"
    ]
    return members.map: {
      "id": it["user_id"],
      "role": it["role"],
    }

  organization_member_add --organization_id/string --user_id/string --role/string:
    client_.rest.insert "roles" {
      "organization_id": organization_id,
      "user_id": user_id,
      "role": role,
    }

  organization_member_remove --organization_id/string --user_id/string:
    client_.rest.delete "roles" --filters=[
      "organization_id=eq.$organization_id",
      "user_id=eq.$user_id",
    ]

  organization_member_set_role --organization_id/string --user_id/string --role/string:
    client_.rest.update "roles" --filters=[
      "organization_id=eq.$organization_id",
      "user_id=eq.$user_id",
    ] { "role": role }

  get_profile --user_id/string?=null -> Map?:
    if not user_id:
      // TODO(florian): we should have the current user cached.
      current_user := client_.auth.get_current_user
      user_id = current_user["id"]
    result := client_.rest.select "profiles_with_email" --filters=[
      "id=eq.$user_id"
    ]
    if result.is_empty: return null
    return result[0]

  update_profile --name/string -> none:
    // TODO(florian): we should have the current user cached.
    current_user := client_.auth.get_current_user
    user_id := current_user["id"]
    client_.rest.update "profiles" --filters=[
      "id=eq.$user_id"
    ] { "name": name }
