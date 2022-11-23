// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import http
import net

import ..broker
import ....shared.server_config

create_broker_cli_http_toit server_config/ServerConfigHttpToit -> BrokerCliHttp:
  id := "toit-http/$server_config.host-$server_config.port"
  return BrokerCliHttp server_config.host server_config.port --id=id

class BrokerCliHttp implements BrokerCli:
  network_/net.Interface? := ?
  id/string
  host/string
  port/int

  constructor .host .port --.id:
    network_ = net.open

  close:
    if network_:
      network_.close
      network_ = null

  is_closed -> bool:
    return network_ == null

  send_request_ command/string data/Map -> any:
    if is_closed: throw "CLOSED"
    client := http.Client network_

    encoded := ubjson.encode {
      "command": command,
      "data": data,
    }
    response := client.post encoded --host=host --port=port --path="/"

    if response.status_code != 200:
      throw "HTTP error: $response.status_code $response.status_message"

    encoded_response := #[]
    while chunk := response.body.read:
      encoded_response += chunk
    decoded := ubjson.decode encoded_response
    if not (decoded.get "success"):
      throw "Broker error: $(decoded.get "error")"

    return decoded["data"]

  device_update_config --device_id/string [block] -> none:
    old := send_request_ "get_config" {"device_id": device_id}
    new := block.call (old or {:})
    send_request_ "update_config" {"device_id": device_id, "config": new}

  upload_image --app_id/string --bits/int content/ByteArray -> none:
    send_request_ "upload_image" {
      "app_id": app_id,
      "bits": bits,
      "content": content,
    }

  upload_firmware --firmware_id/string chunks/List -> none:
    firmware := #[]
    chunks.do: firmware += it
    send_request_ "upload_firmware" {
      "firmware_id": firmware_id,
      "content": firmware,
    }

  download_firmware --id/string -> ByteArray:
    response := send_request_ "download_firmware" {"firmware_id": id}
    return response
