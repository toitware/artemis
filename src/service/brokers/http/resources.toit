// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .connection
import ..broker
import reader show SizedReader
import uuid

class ResourceManagerHttp implements ResourceManager:
  connection_/HttpConnection_

  constructor .connection_:

  fetch_image id/uuid.Uuid --organization_id/string [block] -> none:
    payload :=  {
      "organization_id": organization_id,
      "app_id": id.stringify,
      "word_size": BITS_PER_WORD,
    }
    connection_.send_binary_request "download_image" payload: | reader/SizedReader |
      block.call reader

  fetch_firmware id/string --organization_id/string --offset/int=0 [block] -> none:
    payload := {
      "organization_id": organization_id,
      "firmware_id": id,
      "offset": offset,
    }
    connection_.send_binary_request "download_firmware" payload: | reader/SizedReader |
      block.call reader offset

  report_state device_id/string state/Map -> none:
    connection_.send_request "report_state" {
      "device_id": device_id,
      "state": state,
    }
