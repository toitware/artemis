// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import http
import net
import uuid
import supabase.utils

import ..broker
import ...device
import ...event
import ...ui
import ....shared.server_config

STATUS_IM_A_TEAPOT ::= 418

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
    add_finalizer this:: close

  close:
    if not network_: return
    remove_finalizer this
    network_.close
    network_ = null

  is_closed -> bool:
    return network_ == null

  ensure_authenticated [block]:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  sign_up --email/string --password/string:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  sign_in --email/string --password/string:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  sign_in --provider/string --ui/Ui --open_browser/bool:
    // For simplicity do nothing.
    // This way we can use the same tests for all brokers.

  send_request_ command/string data/Map -> any:
    if is_closed: throw "CLOSED"
    client := http.Client network_
    try:
      encoded := ubjson.encode {
        "command": command,
        "data": data,
      }
      response := client.post encoded --host=host --port=port --path="/"

      if response.status_code != 200 and response.status_code != STATUS_IM_A_TEAPOT:
        throw "HTTP error: $response.status_code $response.status_message"

      decoded := ubjson.decode (utils.read_all response.body)
      if response.status_code == STATUS_IM_A_TEAPOT:
        throw "Broker error: $decoded"
      return decoded
    finally:
      client.close

  update_goal --device_id/string [block] -> none:
    device := get_device --device_id=device_id
    new_goal := block.call device
    send_request_ "update_goal" {"device_id": device_id, "goal": new_goal}

  get_device --device_id/string -> DeviceDetailed:
    current_goal := send_request_ "get_goal" {"device_id": device_id}
    current_state := send_request_ "get_state" {"device_id": device_id}
    return DeviceDetailed --goal=current_goal --state=current_state

  upload_image -> none
      --organization_id/string
      --app_id/uuid.Uuid
      --word_size/int
      content/ByteArray:
    send_request_ "upload_image" {
      "organization_id": organization_id,
      "app_id": app_id.stringify,
      "word_size": word_size,
      "content": content,
    }

  upload_firmware --organization_id/string --firmware_id/string chunks/List -> none:
    firmware := #[]
    chunks.do: firmware += it
    send_request_ "upload_firmware" {
      "organization_id": organization_id,
      "firmware_id": firmware_id,
      "content": firmware,
    }

  download_firmware --organization_id/string --id/string -> ByteArray:
    response := send_request_ "download_firmware" {
      "organization_id": organization_id,
      "firmware_id": id,
    }
    return response

  notify_created --device_id/string --state/Map -> none:
    send_request_ "notify_created" {
      "device_id": device_id,
      "state": state,
    }

  get_events -> Map
      --types/List?=null
      --device_ids/List
      --limit/int=10
      --since/Time?=null:
    response := send_request_ "get_events" {
      "types": types,
      "device_ids": device_ids,
      "limit": limit,
      "since": since and since.ns_since_epoch,
    }
    return response.map: | _ value/List |
      value.map: | event/Map |
        timestamp_ns := event["timestamp_ns"]
        event_type := event["type"]
        data := event["data"]
        Event event_type (Time.epoch --ns=timestamp_ns) data
