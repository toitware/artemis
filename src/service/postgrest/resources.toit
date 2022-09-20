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
    fetch_resource "/storage/v1/object/firmware/$id" block

  fetch_resource path/string [block] -> none:
    response := client_.get host_ --headers=headers_ path
    if response.status_code != status_codes.STATUS_OK: throw "Not found"
    block.call response.body

  fetch_json table/string filters/List=[] -> List?:
    return query client_ headers_ table filters
