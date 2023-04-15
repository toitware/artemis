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

  update_goal --device_id/string [block]:
    // TODO(florian): should we take some locks here to avoid
    // concurrent updates of the goal?
    detailed_device := get_device --device_id=device_id
    new_goal := block.call detailed_device

    client_.rest.rpc "toit_artemis.set_goal" {
      "_device_id": device_id,
      "_goal": new_goal,
    }

  get_device --device_id/string -> DeviceDetailed?:
    current_goal := client_.rest.rpc "toit_artemis.get_goal_no_event" {
      "_device_id": device_id,
    }

    state := client_.rest.rpc "toit_artemis.get_state" {
      "_device_id": device_id,
    }

    if not current_goal and not state: return null

    return DeviceDetailed --goal=current_goal --state=state

  upload_image
      --organization_id/string
      --app_id/uuid.Uuid
      --word_size/int
      content/ByteArray -> none:
    client_.storage.upload --path="toit-artemis-assets/$organization_id/images/$app_id.$word_size" --content=content

  upload_firmware --organization_id/string --firmware_id/string parts/List -> none:
    buffer := bytes.Buffer
    parts.do: | part/ByteArray | buffer.write part
    client_.storage.upload --path="toit-artemis-assets/$organization_id/firmware/$firmware_id" --content=buffer.bytes

  download_firmware --organization_id/string --id/string -> ByteArray:
    buffer := bytes.Buffer
    client_.storage.download --path="toit-artemis-assets/$organization_id/firmware/$id":
      | reader/reader.Reader |
        buffer.write_from reader
    return buffer.bytes

  notify_created --device_id/string --state/Map -> none:
    client_.rest.rpc "toit_artemis.new_provisioned" {
      "_device_id" : device_id,
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
      "_device_ids": device_ids,
      "_limit": limit,
    }
    if since: payload["_since"] = "$since"
    response := client_.rest.rpc "toit_artemis.get_events" payload
    result := {:}
    current_list/List? := null
    current_id/string? := null
    response.do: | row/Map |
      device_id := row["device_id"]
      event_type := row["type"]
      data := row["data"]
      timestamp := row["ts"]
      time := timestamp_to_time_ timestamp
      if device_id != current_id:
        current_id = device_id
        current_list = result.get device_id --init=:[]
      current_list.add (Event event_type time data)
    return result
