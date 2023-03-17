// Copyright (C) 2022 Toitware ApS. All rights reserved.

import certificate_roots
import net
import monitor
import http
import encoding.json
import reader
import supabase
import supabase.utils
import uuid
import bytes

import ..broker
import ...config
import ...device
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

  get_device --device_id/string:
    current_goal := client_.rest.rpc "toit_artemis.get_goal" {
      "_device_id": device_id,
    }

    state := client_.rest.rpc "toit_artemis.get_state" {
      "_device_id": device_id,
    }

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

  print_status -> none:
    print_on_stderr_ "The Supabase client does not support 'status'"
    exit 1

  watch_presence -> none:
    print_on_stderr_ "The Supabase client does not support 'watch-presence'"
    exit 1
