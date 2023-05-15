// Copyright (C) 2023 Toitware ApS. All rights reserved.

import uuid
import .ui

/**
A designation to refer to a specific pod.
*/
class PodDesignation:
  id/uuid.Uuid?
  name/string?
  revision/int?
  tag/string?

  constructor --.id=null --.name=null --.revision=null --.tag=null:
    if id and (name or revision or tag):
      throw "Cannot specify both id and name/revision/tag."
    if not id and not name:
      throw "Must specify either id or name."
    if revision and tag:
      throw "Cannot specify both revision and tag."

  static parse str/string --allow_name_only/bool=false --ui/Ui -> PodDesignation:
    return parse str --allow_name_only=allow_name_only
        --on_error=(: ui.abort it)

  static parse str/string --allow_name_only/bool=false [--on_error] -> PodDesignation:
    name/string? := null
    revision/int? := null
    tag/string? := null
    hash_index := str.index_of "#"
    at_index := str.index_of "@"
    if hash_index >= 0 and at_index >= 0:
      on_error.call "Cannot specify both revision and tag: '$str'."

    if hash_index >= 0:
      if revision:
        on_error.call "Cannot specify the revision as option and in the name."
      revision_string := str[hash_index + 1..]
      revision = int.parse revision_string
          --on_error=(: on_error.call "Invalid revision: '$revision_string'.")
      name = str[..hash_index]
      return PodDesignation --name=name --revision=revision

    if at_index >= 0:
      tag = str[at_index + 1..]
      name = str[..at_index]
      return PodDesignation --name=name --tag=tag

    if str.size == 36 and
        str[8] == '-' and
        str[13] == '-' and
        str[18] == '-' and
        str[23] == '-':
      // Try to parse it as an ID.
      id/uuid.Uuid? := null
      exception := catch:
        id = uuid.parse str
      if exception:
        if allow_name_only:
          name = str
          return PodDesignation --name=name
        on_error.call "Invalid pod uuid: '$str'."
      return PodDesignation --id=id

    if not allow_name_only:
      on_error.call "Invalid pod designation: '$str'."

    return PodDesignation --name=str

  with --tag/string -> PodDesignation:
    if id: throw "Cannot specify tag for designation with id."
    if revision: throw "Cannot specify tag for designation with revision."
    return PodDesignation --name=name --tag=tag

  stringify -> string:
    if id: return id.to_string
    if revision: return "$name#$revision"
    return "$name@$tag"

class PodRegistryDescription:
  id/int
  name/string
  description/string?

  constructor.from_map map/Map:
    id = map["id"]
    name = map["name"]
    description = map.get "description"

  hash_code -> int:
    return (id * 11) & 0x7FFF_FFFF

  operator== other -> bool:
    if other is not PodRegistryDescription: return false
    return id == other.id and name == other.name and description == other.description

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
    created_at = Time.from_string map["created_at"]
    pod_description_id = map["pod_description_id"]
    tags = map["tags"]

  to_json -> Map:
    return {
      "id": id,
      "revision": revision,
      "pod_description_id": pod_description_id,
      "tags": tags,
    }
