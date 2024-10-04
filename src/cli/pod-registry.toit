// Copyright (C) 2023 Toitware ApS. All rights reserved.

import cli show Cli
import uuid

/**
A reference to refer to a specific pod.
*/
class PodReference:
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

  hash-code -> int:
    result := 0
    if id: result = id.hash-code
    if name: result = result * 31 + name.hash-code
    if revision: result = result * 31 + revision.hash-code
    if tag: result = result * 31 + tag.hash-code
    return result

  operator== other -> bool:
    if other is not PodReference: return false
    return id == other.id and name == other.name and revision == other.revision and tag == other.tag

  static parse str/string --allow-name-only/bool=false --cli/Cli -> PodReference:
    return parse str --allow-name-only=allow-name-only
        --on-error=(: cli.ui.abort it)

  static parse str/string --allow-name-only/bool=false [--on-error] -> PodReference:
    name/string? := null
    revision/int? := null
    tag/string? := null
    hash-index := str.index-of "#"
    at-index := str.index-of "@"
    if hash-index >= 0 and at-index >= 0:
      on-error.call "Cannot specify both revision and tag: '$str'."

    if hash-index >= 0:
      if revision:
        on-error.call "Cannot specify the revision as option and in the name."
      revision-string := str[hash-index + 1..]
      revision = int.parse revision-string
          --on-error=(: on-error.call "Invalid revision: '$revision-string'.")
      name = str[..hash-index]
      return PodReference --name=name --revision=revision

    if at-index >= 0:
      tag = str[at-index + 1..]
      name = str[..at-index]
      return PodReference --name=name --tag=tag

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
        if allow-name-only:
          name = str
          return PodReference --name=name
        on-error.call "Invalid pod uuid: '$str'."
      return PodReference --id=id

    if not allow-name-only:
      on-error.call "Invalid pod reference: '$str'."

    return PodReference --name=str

  with --tag/string -> PodReference:
    if id: throw "Cannot specify tag for reference with id."
    if revision: throw "Cannot specify tag for reference with revision."
    return PodReference --name=name --tag=tag

  stringify -> string:
    return to-string

  to-string -> string:
    if id: return id.to-string
    if revision: return "$name#$revision"
    return "$name@$tag"

class PodRegistryDescription:
  id/int
  name/string
  description/string?

  constructor.from-map map/Map:
    id = map["id"]
    name = map["name"]
    description = map.get "description"

  hash-code -> int:
    return (id * 11) & 0x7FFF_FFFF

  operator== other -> bool:
    if other is not PodRegistryDescription: return false
    return id == other.id and name == other.name and description == other.description

  to-json -> Map:
    return {
      "id": id,
      "name": name,
      "description": description,
    }

class PodRegistryEntry:
  id/uuid.Uuid
  revision/int
  created-at/Time
  pod-description-id/int
  tags/List

  constructor.from-map map/Map:
    id = uuid.parse map["id"]
    revision = map["revision"]
    created-at = Time.parse map["created_at"]
    pod-description-id = map["pod_description_id"]
    tags = map["tags"]

  to-json -> Map:
    return {
      "id": "$id",
      "revision": revision,
      "created_at": "$created-at",
      "pod_description_id": pod-description-id,
      "tags": tags,
    }
