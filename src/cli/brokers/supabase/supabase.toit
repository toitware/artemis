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

import .http
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

create_broker_cli_supabase_http server_config/ServerConfigSupabase config/Config -> BrokerCliSupabaseHttp:
  local_storage := ConfigLocalStorage config --auth_key="$(CONFIG_SERVER_AUTHS_KEY).$(server_config.name)"
  supabase_client := supabase.Client --server_config=server_config --local_storage=local_storage
      --certificate_provider=: certificate_roots.MAP[it]
  id := "supabase/$server_config.host"
  return BrokerCliSupabaseHttp supabase_client --id=id

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
    client_.storage.upload --path="/toit-artemis-assets/$organization_id/images/$app_id.$word_size" --content=content

  upload_firmware --organization_id/uuid.Uuid --firmware_id/string parts/List -> none:
    buffer := bytes.Buffer
    parts.do: | part/ByteArray | buffer.write part
    client_.storage.upload --path="/toit-artemis-assets/$organization_id/firmware/$firmware_id" --content=buffer.bytes

  download_firmware --organization_id/uuid.Uuid --id/string -> ByteArray:
    buffer := bytes.Buffer
    client_.storage.download --path="/toit-artemis-assets/$organization_id/firmware/$id":
      | reader/reader.Reader |
        buffer.write_from reader
    return buffer.bytes

  notify_created --device_id/uuid.Uuid --state/Map -> none:
    client_.rest.rpc "toit_artemis.new_provisioned" {
      "_device_id" : "$device_id",
      "_state" : state,
    }

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
      time := Time.from_string timestamp
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
      --tag/string
      --force/bool=false:
    client_.rest.rpc "toit_artemis.set_pod_tag" {
      "_pod_id": "$pod_id",
      "_pod_description_id": pod_description_id,
      "_tag": tag,
      "_force": force,
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

  /** See $(BrokerCli.pod_registry_descriptions --fleet_id --organization_id --names --create_if_absent). */
  pod_registry_descriptions -> List
      --fleet_id/uuid.Uuid
      --organization_id/uuid.Uuid
      --names/List
      --create_if_absent/bool:
    response := client_.rest.rpc "toit_artemis.get_pod_descriptions_by_names" {
      "_fleet_id": "$fleet_id",
      "_organization_id": "$organization_id",
      "_names": names,
      "_create_if_absent": create_if_absent,
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
  pod_registry_pod_ids --fleet_id/uuid.Uuid --references/List -> Map:
    response := client_.rest.rpc "toit_artemis.get_pods_by_reference" {
      "_fleet_id": "$fleet_id",
      "_references": references.map: | reference/PodReference |
        reference_object := {
          "name": reference.name,
        }
        if reference.tag: reference_object["tag"] = reference.tag
        if reference.revision: reference_object["revision"] = reference.revision
        reference_object
    }
    result := {:}
    response.do: | row/Map |
      pod_id := uuid.parse row["pod_id"]
      reference := PodReference
          --name=row["name"]
          --tag=row["tag"]
          --revision=row["revision"]
      result[reference] = pod_id
    return result

  /** See $BrokerCli.pod_registry_upload_pod_part. */
  pod_registry_upload_pod_part -> none
      --organization_id/uuid.Uuid
      --part_id/string
      content/ByteArray:
    client_.storage.upload
        --path="/toit-artemis-pods/$organization_id/part/$part_id"
        --content=content

  /** See $BrokerCli.pod_registry_download_pod_part. */
  pod_registry_download_pod_part part_id/string --organization_id/uuid.Uuid -> ByteArray:
    return client_.storage.download
        --path="/toit-artemis-pods/$organization_id/part/$part_id"

  /** See $BrokerCli.pod_registry_upload_pod_manifest. */
  pod_registry_upload_pod_manifest -> none
      --organization_id/uuid.Uuid
      --pod_id/uuid.Uuid
      content/ByteArray:
    client_.storage.upload
        --path="/toit-artemis-pods/$organization_id/manifest/$pod_id"
        --content=content

  /** See $BrokerCli.pod_registry_download_pod_manifest. */
  pod_registry_download_pod_manifest --organization_id/uuid.Uuid --pod_id/uuid.Uuid -> ByteArray:
    return client_.storage.download
        --path="/toit-artemis-pods/$organization_id/manifest/$pod_id"
