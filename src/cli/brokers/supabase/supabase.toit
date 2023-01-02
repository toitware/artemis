// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import net
import monitor
import http
import encoding.json
import reader
import supabase
import supabase show create_headers create_client

import ..broker
import ....shared.server_config

export create_headers create_client

create_broker_cli_supabase server_config/ServerConfigSupabase -> BrokerCliSupabase:
  supabase_client := supabase.Client --server_config=server_config
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

  device_update_config --device_id/string [block]:
    // TODO(kasper): Share more of this code with the corresponding
    // code in the service.
    info := client_.rest.query "devices" [
      "id=eq.$(device_id)",
    ]
    if not info: throw "Device not found"
    old_config := {:}
    if info.size == 1 and info[0] is Map:
      old_config = info[0].get "config" or old_config

    new_config := block.call old_config

    map := {
      "id"     : device_id,
      "config" : new_config,
    }

    payload := json.encode map
    client_.rest.update_entry "devices" --upsert payload

  upload_image --app_id/string --bits/int content/ByteArray -> none:
    upload_resource_ "assets/images/$app_id.$bits" content

  upload_firmware --firmware_id/string parts/List -> none:
    content := #[]
    parts.do: | part/ByteArray | content += part  // TODO(kasper): Avoid all this copying.
    upload_resource_ "assets/firmware/$firmware_id" content

  upload_resource_ path/string content/ByteArray -> none:
    client_.storage.upload_resource --path=path --content=content

  download_firmware --id/string -> ByteArray:
    content := #[]
    client_.storage.download_resource --path="assets/firmware/$id": | reader/reader.Reader |
      while data := reader.read:
        content += data
    return content

  print_status -> none:
    print_on_stderr_ "The Supabase client does not support 'status'"
    exit 1

  watch_presence -> none:
    print_on_stderr_ "The Supabase client does not support 'watch-presence'"
    exit 1
