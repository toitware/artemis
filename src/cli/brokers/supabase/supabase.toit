// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show Cli
import http
import supabase
import certificate-roots
import uuid show Uuid

import ..http.base
import ..server
import ...config
import ...utils.supabase
import ....shared.server-config

create-server-supabase-http server-config/ServerConfigSupabase --cli/Cli -> ServerSupabase:
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

  return ServerSupabase --id=id supabase-client http-config


class ServerSupabase extends ServerHttp:
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
  Creates the auth-side record for a newly provisioned device.

  $UpdateBrokerSupabase uses this for shared-tenancy deployments before it
    notifies the broker about the device's initial state.
  */
  register-device --device-id/Uuid -> none:
    // The existing schema keeps both columns; they now hold the same ID.
    supabase-client_.rest.insert "devices" --no-return-inserted {
      "id": "$device-id",
      "alias": "$device-id",
      "organization_id": scope.to-json,
    }

  extra-headers -> Map:
    bearer/string := supabase-client_.session_
        ? supabase-client_.session_.access-token
        : supabase-client_.anon_
    return {
      "Authorization": "Bearer $bearer",
    }

class UpdateBrokerSupabase extends UpdateBrokerHttp:
  supabase-server_/ServerSupabase

  constructor .supabase-server_:
    super supabase-server_

  notify-created --device-id/Uuid --state/Map -> none:
    if supabase-server_.tenancy == TENANCY-SHARED:
      supabase-server_.register-device --device-id=device-id
    super --device-id=device-id --state=state

class ArtifactStoreSupabase extends ArtifactStoreHttp:
  constructor server/ServerSupabase:
    super server

class BrokerStateReaderSupabase extends BrokerStateReaderHttp:
  constructor server/ServerSupabase:
    super server

class BrokerEventReaderSupabase extends BrokerEventReaderHttp:
  constructor server/ServerSupabase:
    super server

class PodStoreSupabase extends PodStoreHttp:
  constructor server/ServerSupabase:
    super server
