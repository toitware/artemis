// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import monitor
import http
import encoding.json

import ..mediator
import ...shared.device
import ...shared.postgrest.supabase

class MediatorPostgrest implements Mediator:
  client_/http.Client? := null
  network_/net.Interface? := null

  constructor .client_ .network_:

  close:
    client_ = null
    if network_: network_.close
    network_ = null

  is_closed -> bool:
    return client_ == null

  device_update_config --device_id/string [block]:
    // TODO(kasper): Share more of this code with the corresponding
    // code in the service.
    headers := supabase_create_headers
    info := supabase_query client_ headers "devices" [
      "name=eq.$(device_id)",
    ]
    id := null
    old_config := {:}
    if info.size == 1 and info[0] is Map:
      id = info[0].get "id"
      old_config = info[0].get "config" or old_config

    new_config := block.call old_config
    upsert := id ? "?id=eq.$id" : ""

    map := {
      "config": new_config
    }
    if id:
      map["id"] = id
      headers.add "Prefer" "resolution=merge-duplicates"

    payload := json.encode map
    response := client_.post payload
        --host=SUPABASE_HOST
        --headers=headers
        --path="/rest/v1/devices$upsert"
    // 201 is changed one entry.
    if response.status_code != 201: throw "UGH ($response.status_code)"

  upload_image --app_id/string --bits/int content/ByteArray -> none:
    upload_resource_ "images/$app_id.$bits" content

  upload_firmware --firmware_id/string content/ByteArray -> none:
    upload_resource_ "firmware/$firmware_id" content

  upload_resource_ path/string content/ByteArray -> none:
    headers := supabase_create_headers // TODO(kasper): This seems a bit iffy.
    headers.add "Content-Type" "application/octet-stream"
    headers.add "x-upsert" "true"
    response := client_.post content
        --host=SUPABASE_HOST
        --headers=headers
        --path="/storage/v1/object/$path"
    // 200 is accepted!
    if response.status_code != 200: throw "UGH ($response.status_code)"

  print_status -> none:
    print_on_stderr_ "The Supabase client does not support 'status'"
    exit 1

  watch_presence -> none:
    print_on_stderr_ "The Supabase client does not support 'watch-presence'"
    exit 1
