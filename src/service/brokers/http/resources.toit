// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .connection
import ..broker
import reader show SizedReader

class ResourceManagerHttp implements ResourceManager:
  connection_/HttpConnection_

  constructor .connection_:

  fetch_image id/string --organization_id/string [block] -> none:
    payload :=  {
      "organization_id": organization_id,
      "app_id": id,
      "word_size": BITS_PER_WORD,
    }
    connection_.send_binary_request "download_image" payload: | reader/SizedReader |
      block.call reader

  fetch_firmware id/string --organization_id/string --offset/int=0 [block] -> none:
    PART_SIZE ::= 64 * 1024

    while true:
      payload := {
        "organization_id": organization_id,
        "firmware_id": id,
        "offset": offset,
        "size": PART_SIZE,
      }
      connection_.send_binary_request "download_firmware" payload: | reader/SizedReader total_size/int |
        offset = block.call reader offset
        if offset >= total_size: return


  report_state device_id/string state/Map -> none:
    connection_.send_request "report_state" {
      "device_id": device_id,
      "state": state,
    }
