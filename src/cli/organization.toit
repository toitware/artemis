// Copyright (C) 2023 Toitware ApS. All rights reserved.

class Organization:
  /**
  The organization ID.
  */
  id/string

  /**
  The name of the organization.
  */
  name/string

  constructor --.id --.name:

  constructor.from_map map/Map:
    id = map["id"]
    name = map["name"]
