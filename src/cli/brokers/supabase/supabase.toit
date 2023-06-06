// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import supabase
import certificate_roots

import ..http.base
import ...config
import ...ui
import ....shared.server_config

create_broker_cli_supabase_http server_config/ServerConfigSupabase config/Config -> BrokerCliSupabase:
  local_storage := ConfigLocalStorage config --auth_key="$(CONFIG_SERVER_AUTHS_KEY).$(server_config.name)"
  supabase_client := supabase.Client --server_config=server_config --local_storage=local_storage
      --certificate_provider=: certificate_roots.MAP[it]
  id := "supabase/$server_config.host"

  host_port := server_config.host

  host := host_port
  port := null
  colon_pos := host_port.index_of ":"
  if colon_pos >= 0:
    host = host_port[..colon_pos]
    port = int.parse host_port[colon_pos + 1..]

  root_name := server_config.root_certificate_name
  root_names := root_name ? [root_name] : null
  http_config := ServerConfigHttp
      server_config.name
      --host=host
      --port=port
      --path="/functions/v1/b"
      --admin_headers={
          "apikey": server_config.anon,
          "X-Artemis-Header": "true",
        }
      --device_headers={
        "X-Artemis-Header": "true",
      }
      --root_certificate_names=root_names
      --root_certificate_ders=null
      --poll_interval=server_config.poll_interval

  return BrokerCliSupabase --id=id supabase_client http_config


class BrokerCliSupabase extends BrokerCliHttp:
  client_/supabase.Client? := null

  constructor --id/string .client_ http_config/ServerConfigHttp:
    super --id=id http_config

  ensure_authenticated [block]:
    client_.ensure_authenticated block

  sign_up --email/string --password/string:
    client_.auth.sign_up --email=email --password=password

  sign_in --email/string --password/string:
    client_.auth.sign_in --email=email --password=password

  sign_in --provider/string --ui/Ui --open_browser/bool:
    client_.auth.sign_in
        --provider=provider
        --ui=ui
        --open_browser=open_browser

  extra_headers -> Map:
    bearer/string := client_.session_
        ? client_.session_.access_token
        : client_.anon_
    return {
      "Authorization": "Bearer $bearer",
    }
