// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import net
import monitor
import http
import encoding.json
import reader
import supabase

import ..broker
import ...config
import ...ui
import ....shared.server_config

create_broker_cli_supabase server_config/ServerConfigSupabase config/Config -> BrokerCliSupabase:
  local_storage := ConfigLocalStorage config --auth_key="$(CONFIG_SERVER_AUTHS_KEY).$(server_config.name)"
  supabase_client := supabase.Client --server_config=server_config --local_storage=local_storage
      --certificate_provider=: certificate_roots.MAP[it]
  id := "supabase/$server_config.host"
  return BrokerCliSupabase supabase_client --id=id

class BrokerCliSupabase implements BrokerCli:
  client_/supabase.Client? := null
  /** See $BrokerCli.id. */
  id/string

  constructor --.id/string .client_:

  close:
    if client_:
      client_.close
      client_ = null

  is_closed -> bool:
    return client_ == null

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

  device_update_goal --device_id/string [block]:
    goal_response := client_.rest.select "goals" --filters=[
      "device_id=eq.$(device_id)",
    ]
    current_goal := goal_response.size == 1 ? goal_response[0]["goal"] : null

    state_response := client_.rest.select "devices" --filters=[
      "id=eq.$(device_id)",
    ]
    state := state_response.size == 1 ? state_response[0]["state"] : null

    new_goal := block.call current_goal state

    client_.rest.upsert "goals" {
      "device_id"     : device_id,
      "goal" : new_goal,
    }

  upload_image --app_id/string --word_size/int content/ByteArray -> none:
    client_.storage.upload --path="assets/images/$app_id.$word_size" --content=content

  upload_firmware --firmware_id/string parts/List -> none:
    content := #[]
    parts.do: | part/ByteArray | content += part  // TODO(kasper): Avoid all this copying.
    client_.storage.upload --path="assets/firmware/$firmware_id" --content=content

  download_firmware --id/string -> ByteArray:
    content := #[]
    client_.storage.download --path="assets/firmware/$id": | reader/reader.Reader |
      while data := reader.read:
        content += data
    return content

  notify_created --device_id/string --state/Map -> none:
    client_.rest.rpc "new_provisioned" {
      "_device_id" : device_id,
      "_state" : state,
    }

  print_status -> none:
    print_on_stderr_ "The Supabase client does not support 'status'"
    exit 1

  watch_presence -> none:
    print_on_stderr_ "The Supabase client does not support 'watch-presence'"
    exit 1
