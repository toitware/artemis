// Copyright (C) 2023 Toitware ApS. All rights reserved.

import uuid

class PodhubDescription:
  id/int
  name/string
  description/string?
  tags/List

  constructor.from_map map/Map:
    id = map["id"]
    name = map["name"]
    description = map.get "description"
    tags = map["tags"]

class PodhubEntry:
  id/uuid.Uuid
  pod_description_id/int
  tags/List

  constructor.from_map map/Map:
    id = uuid.Uuid map["id"]
    pod_description_id = map["pod_description_id"]
    tags = map["tags"]
