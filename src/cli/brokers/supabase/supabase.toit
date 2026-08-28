// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show Cli
import http
import supabase
import certificate-roots

import ..http.base
import ..server
import ...config
import ...utils.supabase
import ....shared.server-config

create-server-supabase-http server-config/ServerConfigSupabase --cli/Cli -> ServerSupabase:
  server-config.install-root-certificates
  local-storage := ConfigLocalStorage --cli=cli --auth-key="$(CONFIG-SERVER-AUTHS-KEY).$(server-config.name)"
  supabase-client := supabase.Client --server-config=server-config --local-storage=local-storage
  id := "supabase/$server-config.url"

  http-config := ServerConfigHttp
      server-config.name
      --url="$(server-config.url)/functions/v1"
      --admin-headers=null
      --device-headers=null
      --root-certificate-ders=server-config.root-certificate-ders
      --scope=server-config.scope

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

  extra-headers -> Map:
    bearer/string := supabase-client_.session_
        ? supabase-client_.session_.access-token
        : supabase-client_.anon_
    return {
      "apikey": supabase-client_.anon_,
      "Authorization": "Bearer $bearer",
    }

class BrokerBackendSupabase extends BrokerBackendHttp:
  supabase-server_/ServerSupabase

  constructor .supabase-server_:
    super supabase-server_

class ArtifactStoreSupabase extends ArtifactStoreHttp:
  constructor server/ServerSupabase:
    super server

class PodStoreSupabase extends PodStoreHttp:
  constructor server/ServerSupabase:
    super server
