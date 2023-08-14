// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import supabase
import certificate-roots

import ..http.base
import ...config
import ...ui
import ....shared.server-config

create-broker-cli-supabase-http server-config/ServerConfigSupabase config/Config -> BrokerCliSupabase:
  local-storage := ConfigLocalStorage config --auth-key="$(CONFIG-SERVER-AUTHS-KEY).$(server-config.name)"
  supabase-client := supabase.Client --server-config=server-config --local-storage=local-storage
      --certificate-provider=: certificate-roots.MAP[it]
  id := "supabase/$server-config.host"

  host-port := server-config.host

  host := host-port
  port := null
  colon-pos := host-port.index-of ":"
  if colon-pos >= 0:
    host = host-port[..colon-pos]
    port = int.parse host-port[colon-pos + 1..]

  root-name := server-config.root-certificate-name
  root-names := root-name ? [root-name] : null
  http-config := ServerConfigHttp
      server-config.name
      --host=host
      --port=port
      --path="/functions/v1/b"
      --admin-headers=null
      --device-headers=null
      --root-certificate-names=root-names
      --root-certificate-ders=null
      --poll-interval=server-config.poll-interval

  return BrokerCliSupabase --id=id supabase-client http-config


class BrokerCliSupabase extends BrokerCliHttp:
  client_/supabase.Client? := null

  constructor --id/string .client_ http-config/ServerConfigHttp:
    super --id=id http-config

  ensure-authenticated [block]:
    client_.ensure-authenticated block

  sign-up --email/string --password/string:
    client_.auth.sign-up --email=email --password=password

  sign-in --email/string --password/string:
    client_.auth.sign-in --email=email --password=password

  sign-in --provider/string --ui/Ui --open-browser/bool:
    client_.auth.sign-in
        --provider=provider
        --ui=ui
        --open-browser=open-browser

  extra-headers -> Map:
    bearer/string := client_.session_
        ? client_.session_.access-token
        : client_.anon_
    return {
      "Authorization": "Bearer $bearer",
    }
