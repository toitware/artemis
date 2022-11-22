// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show SizedReader
import http
import http.status_codes
import encoding.json

import ...broker
import ....shared.postgrest as postgres

class ResourceManagerPostgrest implements ResourceManager:
  client_/http.Client
  headers_/http.Headers
  host_/string
  constructor .client_ .host_ .headers_:

  fetch_image id/string [block] -> none:
    fetch_resource_ "/storage/v1/object/assets/images/$id.$BITS_PER_WORD" block

  fetch_firmware id/string --offset/int=0 [block] -> none:
    PART_SIZE ::= 64 * 1024
    while true:
      fetch_resource_ "/storage/v1/object/assets/firmware/$id"
          --offset=offset
          --size=PART_SIZE
          : | reader/SizedReader total_size/int |
            offset = block.call reader offset
            if offset >= total_size: return

  fetch_resource_ path/string --offset/int=0 --size/int?=null [block] -> none:
    partial := false
    headers := headers_
    if offset != 0 or size:
      partial = true
      headers = headers.copy
      end := size ? "$(offset + size - 1)" : ""
      headers.add "Range" "bytes=$offset-$end"
    response := client_.get host_ --headers=headers path
    // Check the status code. The correct result depends on whether
    // or not we're doing a partial fetch.
    status := response.status_code
    body := response.body as SizedReader
    okay := status == 200 or (partial and status == 206)
    if not okay:
      while data := body.read: null // DRAIN!
      throw "Not found ($status)"
    // We got a response we can use. If it is partial we
    // need to decode the response header to find the
    // total size.
    if partial and status != 200:
      // TODO(kasper): Try to avoid doing this for all parts.
      // We only really need to do it for the first.
      range := response.headers.single "Content-Range"
      divider := range.index_of "/"
      total_size := int.parse range[divider + 1..range.size]
      block.call body total_size
    else:
      block.call body body.size
    while data := body.read: null // DRAIN!

  fetch_json table/string filters/List=[] -> List?:
    // TODO(kasper): This needs cleanup. It feels annoying that we
    // cannot use the SupabaseClient abstraction here.
    return postgres.query_ client_ host_ headers_ table filters

  report_status device_id/string status/Map -> none:
    // TODO(kasper): This needs cleanup. It feels annoying that we
    // cannot use the SupabaseClient abstraction here.
    headers := headers_.copy
    headers.add "Prefer" "resolution=merge-duplicates"
    headers.add "Prefer" "return=headers-only"
    map := {
      "device" : device_id,
      "status" : status,
    }
    payload := json.encode map
    response := client_.post payload
        --host=host_
        --headers=headers
        --path="/rest/v1/reports"
    // 201 is changed one entry.
    body := response.body
    while data := body.read: null // DRAIN!
    if response.status_code != 201: throw "UGH ($response.status_code)"
