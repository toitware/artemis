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
  return BrokerCliSupabase supabase_client --id=id


class BrokerCliSupabase extends BrokerCliHttp:
  client_/supabase.Client? := null

  constructor --id/string .client_:
    host_port := client_.host_

    _host := host_port
    _port := null
    colon_pos := host_port.index_of ":"
    if colon_pos >= 0:
      _host = host_port[..colon_pos]
      _port = int.parse host_port[colon_pos + 1..]

    super _host _port --id=id

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

  send_request_ encoded/ByteArray [block]:
    client := http.Client network_
    try:
      anon := client_.anon_
      headers := http.Headers
      headers.add "Content-Type" "application/json"
      bearer/string := client_.session_
          ? client_.session_.access_token
          : anon
      headers.set "Authorization" "Bearer $bearer"
      headers.add "apikey" anon
      response := client.post encoded --host=host --port=port --path="/functions/v1/b" --headers=headers
      block.call response
    finally:
      client.close
