// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show SizedReader
import http
import http.status_codes
import encoding.json

import ..broker
import supabase

class ResourceManagerSupabase implements ResourceManager:
  client_/supabase.Client
  constructor .client_:

  fetch_image id/string [block] -> none:
    client_.storage.download --path="/assets/images/$id.$BITS_PER_WORD" block

  fetch_firmware id/string --offset/int=0 [block] -> none:
    PART_SIZE ::= 64 * 1024
    path := "/assets/firmware/$id"
    while true:
      client_.storage.download
          --path=path
          --offset=offset
          --size=PART_SIZE
          : | reader/SizedReader total_size/int |
            offset = block.call reader offset
            if offset >= total_size: return

  report_status device_id/string status/Map -> none:
    client_.rest.rpc "report_status" {
      "_device_id" : device_id,
      "_status" : status,
    }
