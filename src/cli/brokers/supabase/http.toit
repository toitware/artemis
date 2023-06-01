// Copyright (C) 2023 Toitware ApS. All rights reserved.

import encoding.json
import http
import supabase

import ..http.base
import ...ui

class BrokerCliSupabaseHttp extends BrokerCliHttp:
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
      headers := http.Headers
      headers.add "Content-Type" "application/json"
      bearer/string := ?
      if not client_.session_: bearer = client_.anon_
      else: bearer = client_.session_.access_token
      headers.set "Authorization" "Bearer $bearer"
      headers.add "apikey" client_.anon_
      response := client.post encoded --host=host --port=port --path="/functions/v1/b" --headers=headers
      block.call response
    finally:
      client.close
