// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show Cli
import http
import supabase
import certificate-roots
import uuid show Uuid

import ..http.base
import ...config
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
      --scope=server-config.scope
      --tenancy=server-config.tenancy

  return BrokerCliSupabase --id=id supabase-client http-config


class BrokerCliSupabase extends BrokerCliHttp:
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

  /**
  Registers a newly provisioned device with the broker.

  For a shared-tenancy deployment the broker and the auth provider live
    in the same Supabase project; the broker is responsible for creating
    the device row in the auth-side `devices` table as part of the
    notify-created handshake.
  */
  notify-created --device-id/Uuid --state/Map -> none:
    if server-config_.tenancy == TENANCY-SHARED:
      // The existing schema keeps both columns; they now hold the same ID.
      supabase-client_.rest.insert "devices" --no-return-inserted {
        "id": "$device-id",
        "alias": "$device-id",
        "organization_id": server-config_.scope.to-json,
      }
    super --device-id=device-id --state=state

  extra-headers -> Map:
    bearer/string := supabase-client_.session_
        ? supabase-client_.session_.access-token
        : supabase-client_.anon_
    return {
      "Authorization": "Bearer $bearer",
    }
