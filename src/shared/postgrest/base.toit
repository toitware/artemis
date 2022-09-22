// Copyright (C) 2022 Toitware ApS. All rights reserved.

import net
import monitor
import http
import encoding.json

import ..mediator

interface PostgrestClient:
  close -> none
  is_closed -> bool

  query table/string filters/List -> List?
  update_entry table/string --id/int? payload/ByteArray
  upload_resource --path/string --content/ByteArray

class MediatorCliPostgrest implements MediatorCli:
  client_/PostgrestClient? := null
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
    info := client_.query "devices" [
      "name=eq.$(device_id)",
    ]
    id := null
    old_config := {:}
    if info.size == 1 and info[0] is Map:
      id = info[0].get "id"
      old_config = info[0].get "config" or old_config

    new_config := block.call old_config

    map := {
      "config": new_config
    }

    if id:
      map["id"] = id

    payload := json.encode map
    client_.update_entry "devices" payload --id=id

  upload_image --app_id/string --bits/int content/ByteArray -> none:
    upload_resource_ "images/$app_id.$bits" content

  upload_firmware --firmware_id/string content/ByteArray -> none:
    upload_resource_ "firmware/$firmware_id" content

  upload_resource_ path/string content/ByteArray -> none:
    client_.upload_resource --path=path --content=content

  print_status -> none:
    print_on_stderr_ "The Postgrest client does not support 'status'"
    exit 1

  watch_presence -> none:
    print_on_stderr_ "The Postgrest client does not support 'watch-presence'"
    exit 1
