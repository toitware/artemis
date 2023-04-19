// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show Reader
import uuid

import ..broker
import ...device
import supabase

class ResourceManagerSupabase implements ResourceManager:
  device_/Device
  client_/supabase.Client

  poll_interval_/Duration
  last_poll_us_/int? := null

  constructor .device_ .client_ .poll_interval_:

  fetch_goal --wait/bool -> Map?:
    // We deliberately delay fetching from the cloud, so we
    // can avoid fetching from the cloud over and over again.
    last := last_poll_us_
    if last:
      elapsed := Duration --us=(Time.monotonic_us - last)
      interval := poll_interval_
      if elapsed < interval:
        if not wait: throw DEADLINE_EXCEEDED_ERROR
        sleep interval - elapsed
    // An null goal means that we should revert to the
    // firmware state. We must return it instead of
    // waiting for a non-null one to arrive.
    result := client_.rest.rpc "toit_artemis.get_goal" {
      "_device_id": device_.id
    }
    last_poll_us_ = Time.monotonic_us
    return result

  fetch_image id/uuid.Uuid [block] -> none:
    client_.storage.download
        --public
        --path="/toit-artemis-assets/$device_.organization_id/images/$id.$BITS_PER_WORD"
        block

  fetch_firmware id/string --offset/int=0 [block] -> none:
    path := "/toit-artemis-assets/$device_.organization_id/firmware/$id"
    client_.storage.download
        --public
        --path=path
        --offset=offset
        : | reader/Reader |
          block.call reader offset

  report_state state/Map -> none:
    client_.rest.rpc "toit_artemis.update_state" {
      "_device_id" : device_.id,
      "_state" : state,
    }

  report_event --type/string data/any -> none:
    client_.rest.rpc "toit_artemis.report_event" {
      "_device_id" : device_.id,
      "_type" : type,
      "_data" : data,
    }

  close -> none:
    client_.close
