// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import net
import monitor
import http
import encoding.json
import reader
import supabase
import uuid
import bytes

import ....shared.utils as utils
import ..broker
import ...config
import ...device
import ...event
import ...pod_registry
import ...ui
import ....shared.server_config

create_broker_cli_supabase server_config/ServerConfigSupabase config/Config -> BrokerCliSupabase:
  local_storage := ConfigLocalStorage config --auth_key="$(CONFIG_SERVER_AUTHS_KEY).$(server_config.name)"
  supabase_client := supabase.Client --server_config=server_config --local_storage=local_storage
      --certificate_provider=: certificate_roots.MAP[it]
  id := "supabase/$server_config.host"
  return BrokerCliSupabase supabase_client --id=id

class BrokerCliSupabase implements BrokerCli:
  client_/supabase.Client? := null
  /** See $BrokerCli.id. */
  id/string

  constructor --.id/string .client_:

  is_closed -> bool:
    return client_ == null

  close:
    // TODO(kasper): It is a little bit odd that we close the
    // client that was passed to us from the outside.
    if not client_: return
    client_.close
    client_ = null

  ensure_authenticated [block]:
    client_.ensure_authenticated block

  sign_up --email/string --password/string:
    client_.auth.sign_up --email=email --password=password

  sign_in --email/string --password/string:
    client_.auth.sign_in --email=email --password=password

  sign_in --provider/string --ui/Ui --open_browser/bool:
    client_.auth.sign_in
        --provider=provider
        --ui=ui
        --open_browser=open_browser

  update_goal --device_id/uuid.Uuid [block]:
    // TODO(florian): should we take some locks here to avoid
    // concurrent updates of the goal?
    detailed_devices := get_devices --device_ids=[device_id]
    if detailed_devices.size != 1: throw "Device not found: $device_id"
    detailed_device := detailed_devices[device_id]
    new_goal := block.call detailed_device

    client_.rest.rpc "toit_artemis.set_goal" {
      "_device_id": "$device_id",
      "_goal": new_goal,
    }

  upload_image
      --organization_id/uuid.Uuid
      --app_id/uuid.Uuid
      --word_size/int
      content/ByteArray -> none:
    client_.storage.upload --path="toit-artemis-assets/$organization_id/images/$app_id.$word_size" --content=content

  upload_firmware --organization_id/uuid.Uuid --firmware_id/string parts/List -> none:
    buffer := bytes.Buffer
    parts.do: | part/ByteArray | buffer.write part
    client_.storage.upload --path="toit-artemis-assets/$organization_id/firmware/$firmware_id" --content=buffer.bytes

  download_firmware --organization_id/uuid.Uuid --id/string -> ByteArray:
    buffer := bytes.Buffer
    client_.storage.download --path="toit-artemis-assets/$organization_id/firmware/$id":
      | reader/reader.Reader |
        buffer.write_from reader
    return buffer.bytes

  notify_created --device_id/uuid.Uuid --state/Map -> none:
    client_.rest.rpc "toit_artemis.new_provisioned" {
      "_device_id" : "$device_id",
      "_state" : state,
    }

  // TODO(florian): improve the core Time parsing.
  // TODO(florian): move this function to the supabase library?
  /**
  Parses a Supabase timestamp string into a Time object.

  A Supabase timestamp looks like the following: `2023-03-16T16:59:33.031716`. Despite
    being in UTC, it does not end with 'Z'.
  Also, the built-in Time.parse function does not support parsing the fractional part
    of the timestamp.
  */
  timestamp_to_time_ str/string -> Time:
    parts := str.split "T"
    str_to_int := :int.parse it --on_error=: throw "Cannot parse $it as integer"
    if parts.size != 2: throw "Expected 'T' to separate date and time"
    date_parts := (parts[0].split "-").map str_to_int
    if date_parts.size != 3: throw "Expected 3 segments separated by - for date"
    time_str_parts := parts[1].split ":"
    if time_str_parts.size != 3: throw "Expected 3 segments separated by : for time"
    fraction_index := time_str_parts[2].index_of "."
    ns_part := 0
    if fraction_index >= 0:
      fractional_part := time_str_parts[2][fraction_index + 1 ..]
      time_str_parts[2] = time_str_parts[2][.. fraction_index]
      ns_part = str_to_int.call "$(fractional_part)000000000"[.. 9]
    time_parts := time_str_parts.map str_to_int

    return Time.utc
        date_parts[0]
        date_parts[1]
        date_parts[2]
        time_parts[0]
        time_parts[1]
        time_parts[2]
        --ms=0
        --us=0
        --ns=ns_part

  get_events -> Map
      --types/List?=null
      --device_ids/List
      --limit/int=10
      --since/Time?=null:
    payload := {
      "_types": types or [],
      "_device_ids": device_ids.map: "$it",
      "_limit": limit,
    }
    if since: payload["_since"] = "$since"
    response := client_.rest.rpc "toit_artemis.get_events" payload
    result := {:}
    current_list/List? := null
    current_id/uuid.Uuid? := null
    response.do: | row/Map |
      device_id := uuid.parse row["device_id"]
      event_type := row["type"]
      data := row["data"]
      timestamp := row["ts"]
      time := timestamp_to_time_ timestamp
      if device_id != current_id:
        current_id = device_id
        current_list = result.get device_id --init=:[]
      current_list.add (Event event_type time data)
    return result

  /**
  Fetches the device details for the given device ids.
  Returns a map from id to $DeviceDetailed.
  */
  get_devices --device_ids/List -> Map:
    response := client_.rest.rpc "toit_artemis.get_devices" {
      "_device_ids": device_ids.map: "$it",
    }
    result := {:}
    response.do: | row/Map |
      device_id := uuid.parse row["device_id"]
      goal := row["goal"]
      state := row["state"]
      result[device_id] = DeviceDetailed --goal=goal --state=state
    return result

  /** See $BrokerCli.pod_registry_description_upsert. */
  pod_registry_description_upsert -> int
      --fleet_id/uuid.Uuid
      --organization_id/uuid.Uuid
      --name/string
      --description/string?:
    return client_.rest.rpc "toit_artemis.upsert_pod_description" {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_name": name,
      "_description": description,
    }

  /** See $BrokerCli.pod_registry_add. */
  pod_registry_add -> none
      --pod_description_id/int
      --pod_id/uuid.Uuid:
    client_.rest.rpc "toit_artemis.insert_pod" {
      "_pod_id": "$pod_id",
      "_pod_description_id": pod_description_id,
    }

  /** See $BrokerCli.pod_registry_tag_set. */
  pod_registry_tag_set -> none
      --pod_description_id/int
      --pod_id/uuid.Uuid
      --tag/string:
    client_.rest.rpc "toit_artemis.insert_pod_tag" {
      "_pod_id": "$pod_id",
      "_pod_description_id": pod_description_id,
      "_tag": tag,
    }

  /** See $BrokerCli.pod_registry_tag_remove. */
  pod_registry_tag_remove -> none
      --pod_description_id/int
      --tag/string:
    client_.rest.rpc "toit_artemis.delete_pod_tag" {
      "_pod_description_id": pod_description_id,
      "_tag": tag,
    }

  /** See $BrokerCli.pod_registry_descriptions. */
  pod_registry_descriptions --fleet_id/uuid.Uuid -> List:
    response := client_.rest.rpc "toit_artemis.get_pod_descriptions" {
      "_fleet_id": "$fleet_id",
    }
    return response.map: PodRegistryDescription.from_map it

  /** See $(BrokerCli.pod_registry_descriptions --ids). */
  pod_registry_descriptions --ids/List -> List:
    response := client_.rest.rpc "toit_artemis.get_pod_descriptions_by_ids" {
      "_description_ids": ids,
    }
    return response.map: PodRegistryDescription.from_map it

  /** See $(BrokerCli.pod_registry_descriptions --fleet_id --names). */
  pod_registry_descriptions --fleet_id/uuid.Uuid --names/List -> List:
    response := client_.rest.rpc "toit_artemis.get_pod_descriptions_by_names" {
      "_fleet_id": "$fleet_id",
      "_names": names,
    }
    return response.map: PodRegistryDescription.from_map it

  /** See $(BrokerCli.pod_registry_pods --pod_description_id). */
  pod_registry_pods --pod_description_id/int -> List:
    response := client_.rest.rpc "toit_artemis.get_pods" {
      "_pod_description_id": pod_description_id,
      "_limit": 1000,
      "_offset": 0,
    }
    return response.map: PodRegistryEntry.from_map it

  /** See $(BrokerCli.pod_registry_pods --fleet_id --pod_ids). */
  pod_registry_pods --fleet_id --pod_ids/List -> List:
    response := client_.rest.rpc "toit_artemis.get_pods_by_ids" {
      "_fleet_id": "$fleet_id",
      "_pod_ids": pod_ids.map: "$it",
    }
    return response.map: PodRegistryEntry.from_map it

  /** See $BrokerCli.pod_registry_pod_ids. */
  pod_registry_pod_ids --fleet_id/uuid.Uuid --names_tags/List -> List:
    result := client_.rest.rpc "toit_artemis.get_pods_by_name_and_tag" {
      "_fleet_id": "$fleet_id",
      "_names_tags": names_tags,
    }
    result.do: it["pod_id"] = uuid.parse it["pod_id"]
    return result


