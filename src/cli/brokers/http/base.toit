// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import http
import net
import uuid

import ..broker
import ...device
import ...event
import ...release
import ...ui
import ....shared.server_config
import ....shared.utils as utils

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

      if response.status_code != http.STATUS_OK and response.status_code != STATUS_IM_A_TEAPOT:
        throw "HTTP error: $response.status_code $response.status_message"

      decoded := ubjson.decode (utils.read_all response.body)
      if response.status_code == STATUS_IM_A_TEAPOT:
        throw "Broker error: $decoded"
      return decoded
    finally:
      client.close

  update_goal --device_id/uuid.Uuid [block] -> none:
    detailed_devices := get_devices --device_ids=[device_id]
    if detailed_devices.size != 1: throw "Device not found: $device_id"
    detailed_device := detailed_devices[device_id]
    new_goal := block.call detailed_device
    send_request_ "update_goal" {"device_id": "$device_id", "goal": new_goal}

  get_devices --device_ids/List -> Map:
    response := send_request_ "get_devices" {"device_ids": device_ids.map: "$it"}
    result := {:}
    response.do: | key value |
      result[uuid.parse key] = DeviceDetailed --goal=value["goal"] --state=value["state"]
    return result

  upload_image -> none
      --organization_id/uuid.Uuid
      --app_id/uuid.Uuid
      --word_size/int
      content/ByteArray:
    send_request_ "upload_image" {
      "organization_id": "$organization_id",
      "app_id": "$app_id",
      "word_size": word_size,
      "content": content,
    }

  upload_firmware --organization_id/uuid.Uuid --firmware_id/string chunks/List -> none:
    firmware := #[]
    chunks.do: firmware += it
    send_request_ "upload_firmware" {
      "organization_id": "$organization_id",
      "firmware_id": firmware_id,
      "content": firmware,
    }

  download_firmware --organization_id/uuid.Uuid --id/string -> ByteArray:
    response := send_request_ "download_firmware" {
      "organization_id": "$organization_id",
      "firmware_id": id,
    }
    return response

  notify_created --device_id/uuid.Uuid --state/Map -> none:
    send_request_ "notify_created" {
      "device_id": "$device_id",
      "state": state,
    }

  get_events -> Map
      --types/List?=null
      --device_ids/List
      --limit/int=10
      --since/Time?=null:
    response := send_request_ "get_events" {
      "types": types,
      "device_ids": device_ids.map: "$it",
      "limit": limit,
      "since": since and since.ns_since_epoch,
    }
    result := {:}
    response.do: | id_string/string value/List |
      decoded_events := value.map: | event/Map |
        timestamp_ns := event["timestamp_ns"]
        event_type := event["type"]
        data := event["data"]
        Event event_type (Time.epoch --ns=timestamp_ns) data
      result[uuid.parse id_string] = decoded_events
    return result

  /**
  Creates a new release with the given $version and $description for the $fleet_id.
  */
  release_create -> int
      --fleet_id/uuid.Uuid
      --organization_id/uuid.Uuid
      --version/string
      --description/string?:
    return send_request_ "release_create" {
      "fleet_id": "$fleet_id",
      "organization_id": "$organization_id",
      "version": version,
      "description": description,
    }

  /**
  Adds a new artifact to the given $release_id.

  The $group must be a valid string and should be "" for the default group.
  The $encoded_firmware is a base64 encoded string of the hashes of the firmware.
  */
  release_add_artifact --release_id/int --group/string --encoded_firmware/string -> none:
    send_request_ "release_add_artifact" {
      "release_id": release_id,
      "group": group,
      "encoded": encoded_firmware,
    }

  /**
  Fetches releases for the given $fleet_id.

  The $limit is the maximum number of releases to return (ordered by most recent
    first).

  Returns a list of $Release objects.
  */
  release_get --fleet_id/uuid.Uuid  --limit/int=100 -> List:
    response := send_request_ "release_get_fleet_id" {
      "fleet_id": "$fleet_id",
      "limit": limit,
    }
    return response.map: Release.from_map it

  /**
  Fetches the releases with the given $release_ids.

  Returns a list of $Release objects.
  */
  release_get --release_ids/List -> List:
    response := send_request_ "release_get_release_ids" {
      "release_ids": release_ids,
    }
    return response.map: Release.from_map it

  /**
  Returns the release ids for the given $encoded_firmwares in the given $fleet_id.

  Returns a map from encoded firmware to release id.
  If an encoded firmware is not found, the map does not contain an entry for it.
  */
  release_get_ids_for --fleet_id/uuid.Uuid --encoded_firmwares/List -> Map:
    return send_request_ "release_get_ids_for_encoded" {
      "fleet_id": "$fleet_id",
      "encoded_entries": encoded_firmwares,
    }
