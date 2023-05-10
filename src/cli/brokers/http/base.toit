// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.ubjson
import http
import net
import uuid

import ..broker
import ...device
import ...event
import ...pod_registry
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
    send_request_ "upload" {
      "path": "/toit-artemis-assets/$organization_id/images/$app_id.$word_size",
      "content": content,
    }

  upload_firmware --organization_id/uuid.Uuid --firmware_id/string chunks/List -> none:
    firmware := #[]
    chunks.do: firmware += it
    send_request_ "upload" {
      "path": "/toit-artemis-assets/$organization_id/firmware/$firmware_id",
      "content": firmware,
    }

  download_firmware --organization_id/uuid.Uuid --id/string -> ByteArray:
    return send_request_ "download" {
      "path": "/toit-artemis-assets/$organization_id/firmware/$id",
    }

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

  /** See $BrokerCli.pod_registry_description_upsert. */
  pod_registry_description_upsert -> int
      --fleet_id/uuid.Uuid
      --organization_id/uuid.Uuid
      --name/string
      --description/string?:
    return send_request_ "pod_registry_description_upsert" {
      "fleet_id": "$fleet_id",
      "organization_id": "$organization_id",
      "name": name,
      "description": description,
    }

  /** See $BrokerCli.pod_registry_add. */
  pod_registry_add -> none
      --pod_description_id/int
      --pod_id/uuid.Uuid:
    send_request_ "pod_registry_add" {
      "pod_description_id": pod_description_id,
      "pod_id": "$pod_id",
    }

  /** See $BrokerCli.pod_registry_tag_set. */
  pod_registry_tag_set -> none
      --pod_description_id/int
      --pod_id/uuid.Uuid
      --tag/string:
    send_request_ "pod_registry_tag_set" {
      "pod_description_id": pod_description_id,
      "pod_id": "$pod_id",
      "tag": tag,
    }

  /** See $BrokerCli.pod_registry_tag_remove. */
  pod_registry_tag_remove -> none
      --pod_description_id/int
      --tag/string:
    send_request_ "pod_registry_tag_remove" {
      "pod_description_id": pod_description_id,
      "tag": tag,
    }

  /** See $BrokerCli.pod_registry_descriptions. */
  pod_registry_descriptions --fleet_id/uuid.Uuid -> List:
    response := send_request_ "pod_registry_descriptions" {
      "fleet_id": "$fleet_id",
    }
    return response.map: PodRegistryDescription.from_map it

  /** See $(BrokerCli.pod_registry_descriptions --ids). */
  pod_registry_descriptions --ids/List -> List:
    response := send_request_ "pod_registry_descriptions_by_ids" {
      "ids": ids,
    }
    return response.map: PodRegistryDescription.from_map it

  /** See $(BrokerCli.pod_registry_descriptions --fleet_id --organization_id --names --create_if_missing). */
  pod_registry_descriptions -> List
      --fleet_id/uuid.Uuid
      --organization_id/uuid.Uuid
      --names/List
      --create_if_missing/bool:
    response := send_request_ "pod_registry_descriptions_by_names" {
      "fleet_id": "$fleet_id",
      "organization_id": "$organization_id",
      "names": names,
      "create_if_missing": create_if_missing,
    }
    return response.map: PodRegistryDescription.from_map it

  /** See $(BrokerCli.pod_registry_pods --pod_description_id). */
  pod_registry_pods --pod_description_id/int -> List:
    response := send_request_ "pod_registry_pods" {
      "pod_description_id": pod_description_id,
    }
    return response.map: PodRegistryEntry.from_map it

  /** See $(BrokerCli.pod_registry_pods --fleet_id --pod_ids). */
  pod_registry_pods --fleet_id/uuid.Uuid --pod_ids/List -> List:
    response := send_request_ "pod_registry_pods_by_ids" {
      "fleet_id": "$fleet_id",
      "pod_ids": (pod_ids.map: "$it"),
    }
    return response.map: PodRegistryEntry.from_map it

  /** See $BrokerCli.pod_registry_pod_ids. */
  pod_registry_pod_ids --fleet_id/uuid.Uuid --names_tags/List -> List:
    result := send_request_ "pod_registry_pod_ids_by_names_tags" {
      "fleet_id": "$fleet_id",
      "names_tags": names_tags,
    }
    result.do: it["pod_id"] = uuid.parse it["pod_id"]
    return result

  /** See $BrokerCli.pod_registry_upload_pod_part. */
  pod_registry_upload_pod_part -> none
      --organization_id/uuid.Uuid
      --part_id/string
      content/ByteArray:
    send_request_ "upload" {
      "path": "toit-artemis-pods/$organization_id/part/$part_id",
      "content": content,
    }

  /** See $BrokerCli.pod_registry_download_pod_part. */
  pod_registry_download_pod_part part_id/string --organization_id/uuid.Uuid -> ByteArray:
    return send_request_ "download" {
      "path": "toit-artemis-pods/$organization_id/part/$part_id",
    }

  /** See $BrokerCli.pod_registry_upload_pod_manifest. */
  pod_registry_upload_pod_manifest -> none
      --organization_id/uuid.Uuid
      --pod_id/uuid.Uuid
      content/ByteArray:
    send_request_ "upload" {
      "path": "toit-artemis-pods/$organization_id/manifest/$pod_id",
      "content": content,
    }

  /** See $BrokerCli.pod_registry_download_pod_manifest. */
  pod_registry_download_pod_manifest --organization_id/uuid.Uuid --pod_id/uuid.Uuid -> ByteArray:
    return send_request_ "download" {
      "path": "toit-artemis-pods/$organization_id/manifest/$pod_id",
    }
