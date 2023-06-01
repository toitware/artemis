// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.json
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
import ....shared.constants show *

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

  send_request_ command/int data/any -> any:
    if is_closed: throw "CLOSED"
    encoded/ByteArray := ?
    if command == COMMAND_UPLOAD_:
      path := data["path"]
      content := data["content"]
      encoded = #[COMMAND_UPLOAD_] + path.to_byte_array + #[0] + content
    else:
      encoded = #[command] + (json.encode data)

    send_request_ encoded: | response/http.Response |
      if response.status_code != http.STATUS_OK and response.status_code != http.STATUS_IM_A_TEAPOT:
        throw "HTTP error: $response.status_code $response.status_message"

      if command == COMMAND_DOWNLOAD_ and response.status_code != http.STATUS_IM_A_TEAPOT:
        return utils.read_all response.body

      decoded := json.decode_stream response.body
      if response.status_code == http.STATUS_IM_A_TEAPOT:
        throw "Broker error: $decoded"
      return decoded
    unreachable

  send_request_ encoded/ByteArray [block]:
    client := http.Client network_
    try:
      response := client.post encoded --host=host --port=port --path="/"
      block.call response
    finally:
      client.close

  update_goal --device_id/uuid.Uuid [block] -> none:
    detailed_devices := get_devices --device_ids=[device_id]
    if detailed_devices.size != 1: throw "Device not found: $device_id"
    detailed_device := detailed_devices[device_id]
    new_goal := block.call detailed_device
    send_request_ COMMAND_UPDATE_GOAL_ {
      "_device_id": "$device_id",
      "_goal": new_goal
    }

  get_devices --device_ids/List -> Map:
    response := send_request_ COMMAND_GET_DEVICES_ {
      "_device_ids": device_ids.map: "$it"
    }
    result := {:}
    response.do: | row/Map |
      device_id := uuid.parse row["device_id"]
      goal := row["goal"]
      state := row["state"]
      result[device_id] = DeviceDetailed --goal=goal --state=state
    return result

  upload_image -> none
      --organization_id/uuid.Uuid
      --app_id/uuid.Uuid
      --word_size/int
      content/ByteArray:
    send_request_ COMMAND_UPLOAD_ {
      "path": "/toit-artemis-assets/$organization_id/images/$app_id.$word_size",
      "content": content,
    }

  upload_firmware --organization_id/uuid.Uuid --firmware_id/string chunks/List -> none:
    firmware := #[]
    chunks.do: firmware += it
    send_request_ COMMAND_UPLOAD_ {
      "path": "/toit-artemis-assets/$organization_id/firmware/$firmware_id",
      "content": firmware,
    }

  download_firmware --organization_id/uuid.Uuid --id/string -> ByteArray:
    return send_request_ COMMAND_DOWNLOAD_ {
      "path": "/toit-artemis-assets/$organization_id/firmware/$id",
    }

  notify_created --device_id/uuid.Uuid --state/Map -> none:
    send_request_ COMMAND_NOTIFY_BROKER_CREATED_ {
      "_device_id": "$device_id",
      "_state": state,
    }

  get_events -> Map
      --types/List?=null
      --device_ids/List
      --limit/int=10
      --since/Time?=null:
    payload := {
      "_types": types,
      "_device_ids": device_ids.map: "$it",
      "_limit": limit,
    }
    if since: payload["_since"] = since.utc.to_iso8601_string
    response := send_request_ COMMAND_GET_EVENTS_ payload
    result := {:}
    current_list/List? := null
    current_id/uuid.Uuid? := null
    response.do: | row/Map |
      device_id := uuid.parse row["device_id"]
      event_type := row["type"]
      data := row["data"]
      timestamp := row["ts"]
      time := Time.from_string timestamp
      if device_id != current_id:
        current_id = device_id
        current_list = result.get device_id --init=:[]
      current_list.add (Event event_type time data)
    return result

  /** See $BrokerCli.pod_registry_description_upsert. */
  pod_registry_description_upsert -> int
      --fleet_id/uuid.Uuid
      --organization_id/uuid.Uuid
      --name/string
      --description/string?:
    return send_request_ COMMAND_POD_REGISTRY_DESCRIPTION_UPSERT_ {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_name": name,
      "_description": description,
    }

  /** See $BrokerCli.pod_registry_add. */
  pod_registry_add -> none
      --pod_description_id/int
      --pod_id/uuid.Uuid:
    send_request_ COMMAND_POD_REGISTRY_ADD_ {
      "_pod_description_id": pod_description_id,
      "_pod_id": "$pod_id",
    }

  /** See $BrokerCli.pod_registry_tag_set. */
  pod_registry_tag_set -> none
      --pod_description_id/int
      --pod_id/uuid.Uuid
      --tag/string
      --force/bool=false:
    send_request_ COMMAND_POD_REGISTRY_TAG_SET_ {
      "_pod_description_id": pod_description_id,
      "_pod_id": "$pod_id",
      "_tag": tag,
      "_force": force,
    }

  /** See $BrokerCli.pod_registry_tag_remove. */
  pod_registry_tag_remove -> none
      --pod_description_id/int
      --tag/string:
    send_request_ COMMAND_POD_REGISTRY_TAG_REMOVE_ {
      "_pod_description_id": pod_description_id,
      "_tag": tag,
    }

  /** See $BrokerCli.pod_registry_descriptions. */
  pod_registry_descriptions --fleet_id/uuid.Uuid -> List:
    response := send_request_ COMMAND_POD_REGISTRY_DESCRIPTIONS_ {
      "_fleet_id": "$fleet_id",
    }
    return response.map: PodRegistryDescription.from_map it

  /** See $(BrokerCli.pod_registry_descriptions --ids). */
  pod_registry_descriptions --ids/List -> List:
    response := send_request_ COMMAND_POD_REGISTRY_DESCRIPTIONS_BY_IDS_ {
      "_description_ids": ids,
    }
    return response.map: PodRegistryDescription.from_map it

  /** See $(BrokerCli.pod_registry_descriptions --fleet_id --organization_id --names --create_if_absent). */
  pod_registry_descriptions -> List
      --fleet_id/uuid.Uuid
      --organization_id/uuid.Uuid
      --names/List
      --create_if_absent/bool:
    response := send_request_ COMMAND_POD_REGISTRY_DESCRIPTIONS_BY_NAMES_ {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_names": names,
      "_create_if_absent": create_if_absent,
    }
    return response.map: PodRegistryDescription.from_map it

  /** See $(BrokerCli.pod_registry_pods --pod_description_id). */
  pod_registry_pods --pod_description_id/int -> List:
    response := send_request_ COMMAND_POD_REGISTRY_PODS_ {
      "_pod_description_id": pod_description_id,
      "_limit": 1000,
      "_offset": 0,
    }
    return response.map: PodRegistryEntry.from_map it

  /** See $(BrokerCli.pod_registry_pods --fleet_id --pod_ids). */
  pod_registry_pods --fleet_id/uuid.Uuid --pod_ids/List -> List:
    response := send_request_ COMMAND_POD_REGISTRY_PODS_BY_IDS_ {
      "_fleet_id": "$fleet_id",
      "_pod_ids": (pod_ids.map: "$it"),
    }
    return response.map: PodRegistryEntry.from_map it

  /** See $BrokerCli.pod_registry_pod_ids. */
  pod_registry_pod_ids --fleet_id/uuid.Uuid --references/List -> Map:
    response := send_request_ COMMAND_POD_REGISTRY_POD_IDS_BY_REFERENCE_ {
      "_fleet_id": "$fleet_id",
      "_references": references.map: | reference/PodReference |
        ref := {
          "name": reference.name,
        }
        if reference.tag: ref["tag"] = reference.tag
        if reference.revision: ref["revision"] = reference.revision
        ref,
    }
    result := {:}
    response.do: | it/Map |
      pod_id := uuid.parse it["pod_id"]
      reference := PodReference
          --name=it["name"]
          --tag=it.get "tag"
          --revision=it.get "revision"
      result[reference] = pod_id
    return result

  /** See $BrokerCli.pod_registry_upload_pod_part. */
  pod_registry_upload_pod_part -> none
      --organization_id/uuid.Uuid
      --part_id/string
      content/ByteArray:
    send_request_ COMMAND_UPLOAD_ {
      "path": "/toit-artemis-pods/$organization_id/part/$part_id",
      "content": content,
    }

  /** See $BrokerCli.pod_registry_download_pod_part. */
  pod_registry_download_pod_part part_id/string --organization_id/uuid.Uuid -> ByteArray:
    return send_request_ COMMAND_DOWNLOAD_ {
      "path": "/toit-artemis-pods/$organization_id/part/$part_id",
    }

  /** See $BrokerCli.pod_registry_upload_pod_manifest. */
  pod_registry_upload_pod_manifest -> none
      --organization_id/uuid.Uuid
      --pod_id/uuid.Uuid
      content/ByteArray:
    send_request_ COMMAND_UPLOAD_ {
      "path": "/toit-artemis-pods/$organization_id/manifest/$pod_id",
      "content": content,
    }

  /** See $BrokerCli.pod_registry_download_pod_manifest. */
  pod_registry_download_pod_manifest --organization_id/uuid.Uuid --pod_id/uuid.Uuid -> ByteArray:
    return send_request_ COMMAND_DOWNLOAD_ {
      "path": "/toit-artemis-pods/$organization_id/manifest/$pod_id",
    }
