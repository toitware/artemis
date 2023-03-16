// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show SizedReader
import uuid

import .connection
import ..broker
import ...device

class ResourceManagerHttp implements ResourceManager:
  device_/Device
  connection_/HttpConnection_

  constructor .device_ .connection_:

  fetch_image id/uuid.Uuid [block] -> none:
    payload :=  {
      "organization_id": device_.organization_id,
      "app_id": id.stringify,
      "word_size": BITS_PER_WORD,
    }
    connection_.send_binary_request "download_image" payload: | reader/SizedReader |
      block.call reader

  fetch_firmware id/string --offset/int=0 [block] -> none:
    payload := {
      "organization_id": device_.organization_id,
      "firmware_id": id,
      "offset": offset,
    }
    connection_.send_binary_request "download_firmware" payload: | reader/SizedReader |
      block.call reader offset

  report_state state/Map -> none:
    connection_.send_request "report_state" {
      "device_id": device_.id,
      "state": state,
    }

  report_event --type/string data/any -> none:
    connection_.send_request "report_event" {
      "device_id": device_.id,
      "type": type,
      "data": data,
    }
