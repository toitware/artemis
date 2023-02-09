// Copyright (C) 2022 Toitware ApS. All rights reserved.

import bytes
import .connection
import ..broker

class ResourceManagerHttp implements ResourceManager:
  connection_/HttpConnection_
  last_firmware_id_/string? := null
  last_firmware_/ByteArray? := null

  constructor .connection_:

  fetch_image id/string [block] -> none:
    response := connection_.send_request "download_image" {
      "app_id": id,
      "word_size": BITS_PER_WORD,
    }
    image := response
    block.call (bytes.Reader image)

  fetch_firmware id/string --offset/int=0 [block] -> none:
    PART_SIZE ::= 64 * 1024

    firmware := ?
    if last_firmware_id_ == id:
      firmware = last_firmware_
    else:
      firmware = connection_.send_request "download_firmware" {
        "firmware_id": id,
        "offset": offset,
      }
      last_firmware_id_ = id
      last_firmware_ = firmware

    while true:
      List.chunk_up offset firmware.size PART_SIZE: | from to |
        reader := bytes.Reader firmware[from..to]
        next_offset := block.call reader from
        if next_offset != to:
          // The caller wants a different offset to continue from (most likely
          // skipping over some bytes.)
          // Skip to the outer while loop.
          continue
      // The chunk up finished.
      break

  report_state device_id/string state/Map -> none:
    connection_.send_request "report_state" {
      "device_id": device_id,
      "state": state,
    }
