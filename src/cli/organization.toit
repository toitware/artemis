// Copyright (C) 2023 Toitware ApS. All rights reserved.

import uuid

class Organization:
  /**
  The organization ID.
  */
  id/uuid.Uuid

  /**
  The name of the organization.
  */
  name/string

  constructor --.id --.name:

  constructor.from-map map/Map:
    id = uuid.parse map["id"]
    name = map["name"]

/**
A detailed version of the organization class.

This class contains additional information, like the time the
  organization was created, or the members of it.
*/
class OrganizationDetailed extends Organization:
  /** The time the organization was created. */
  created-at/Time
  // TODO(florian): add members.

  constructor --id/uuid.Uuid --name/string --.created-at:
    super --id=id --name=name

  constructor.from-map map/Map:
    created-at = Time.parse map["created_at"]
    super.from-map map
