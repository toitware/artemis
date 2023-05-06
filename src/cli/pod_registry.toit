// Copyright (C) 2023 Toitware ApS. All rights reserved.

import uuid

class PodRegistryDescription:
  id/int
  name/string
  description/string?

  constructor.from_map map/Map:
    id = map["id"]
    name = map["name"]
    description = map.get "description"

class PodRegistryEntry:
  id/uuid.Uuid
  revision/int
  pod_description_id/int
  tags/List

  constructor.from_map map/Map:
    id = uuid.parse map["id"]
    revision = map["revision"]
    pod_description_id = map["pod_description_id"]
    tags = map["tags"]
