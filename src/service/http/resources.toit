// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.base64
import bytes
import .connection
import ..mediator_service

class ResourceManagerHttp implements ResourceManager:
  connection_/HttpConnection_
  last_firmware_id_/string? := null
  last_firmware_/ByteArray? := null

  constructor .connection_:

  fetch_image id/string [block] -> none:
    response := connection_.send_request "download_image" {
      "app_id": id,
    }
    image := base64.decode response["content"]
    block.call image image.size

  fetch_firmware id/string --offset/int=0 [block] -> none:
    firmware := ?
    if last_firmware_id_ == id:
      firmware = last_firmware_
    else:
      response := connection_.send_request "download_firmware" {
        "firmware_id": id,
        "offset": offset,
      }
      firmware = base64.decode response["content"]
      last_firmware_id_ = id
      last_firmware_ = firmware

    reader := bytes.Reader firmware
    block.call reader firmware.size

  report_status device_id/string status/Map -> none:
    connection_.send_request "report_status" {
      "device_id": device_id,
      "status": status,
    }
