// Copyright (C) 2022 Toitware ApS. All rights reserved.

import reader show Reader
import uuid

import ..broker
import ...device
import supabase

class ResourceManagerSupabase implements ResourceManager:
  device_/Device
  client_/supabase.Client
  constructor .device_ .client_:

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
