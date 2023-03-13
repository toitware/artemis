// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show SizedReader
import http
import http.status_codes
import encoding.json
import uuid

import ..broker
import supabase

class ResourceManagerSupabase implements ResourceManager:
  client_/supabase.Client
  constructor .client_:

  fetch_image id/uuid.Uuid --organization_id/string [block] -> none:
    client_.storage.download
        --public
        --path="/toit-artemis-assets/$organization_id/images/$id.$BITS_PER_WORD"
        block

  fetch_firmware id/string --organization_id/string --offset/int=0 [block] -> none:
    path := "/toit-artemis-assets/$organization_id/firmware/$id"
    client_.storage.download
        --public
        --path=path
        --offset=offset
        : | reader/SizedReader |
          block.call reader offset

  report_state device_id/string state/Map -> none:
    client_.rest.rpc "toit_artemis.update_state" {
      "_device_id" : device_id,
      "_state" : state,
    }
