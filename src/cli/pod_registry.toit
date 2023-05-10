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

  hash_code -> int:
    return (id * 11) & 0xFFFFFFFF

  to_json -> Map:
    return {
      "id": id,
      "name": name,
      "description": description,
    }

class PodRegistryEntry:
  id/uuid.Uuid
  revision/int
  created_at/Time
  pod_description_id/int
  tags/List

  constructor.from_map map/Map:
    id = uuid.parse map["id"]
    revision = map["revision"]
    created_at =  Time.from_string map["created_at"]
    pod_description_id = map["pod_description_id"]
    tags = map["tags"]

  to_json -> Map:
    return {
      "id": id,
      "revision": revision,
      "pod_description_id": pod_description_id,
      "tags": tags,
    }
