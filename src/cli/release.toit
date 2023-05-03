// Copyright (C) 2023 Toitware ApS. All rights reserved.

import uuid

class Release:
  /** The release ID. */
  id/int

  /** The fleet ID. */
  fleet_id/uuid.Uuid

  /**
  The version.
  Can be any string.
  */
  version/string

  /**
  An optional description.
  */
  description/string?

  /**
  The tags that are available for this release.
  */
  tags/List

  constructor --.id --.fleet_id --.version --.description --.tags:

  constructor.from_map map/Map:
    id = map["id"]
    fleet_id = uuid.parse map["fleet_id"]
    version = map["version"]
    description = map.get "description"
    tags = map["tags"]
