// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show SizedReader
import http
import http.status_codes
import encoding.json

import ..resources

import ...shared.postgrest.supabase

class ResourceManagerPostgrest implements ResourceManager:
  client_/http.Client
  headers_/http.Headers
  host_/string
  constructor .client_ .host_ .headers_:

  fetch_image id/string [block] -> none:
    fetch_resource "/storage/v1/object/images/$id.$BITS_PER_WORD" block

  fetch_firmware id/string [block] -> none:
    PART_SIZE ::= 128 * 1024
    offset := 0
    while true:
      size/int? := null
      fetch_resource "/storage/v1/object/firmware/$id"
          --offset=offset
          --size=PART_SIZE:
        | reader/SizedReader |
        size = reader.size
        // TODO(kasper): The 'size' we pass here is wrong.
        block.call reader 0 size
      if size < PART_SIZE: return
      offset += size

  fetch_resource path/string --offset/int=0 --size/int?=null [block] -> none:
    partial/bool := false
    headers := headers_
    if offset != 0 or size:
      partial = true
      headers = headers.copy
      headers.add "Range" "bytes=$offset-$(offset + size - 1)"
    response := client_.get host_ --headers=headers path
    // TODO(kasper): check response 200 or 206 properly.
    if response.status_code != 200 and response.status_code != 206:
      throw "Not found"
    body := response.body as SizedReader
    block.call response.body

  fetch_json table/string filters/List=[] -> List?:
    return supabase_query client_ headers_ table filters
