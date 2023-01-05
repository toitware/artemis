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

class DetailedOrganization extends Organization:
  /** The time the organization was created. */
  created_at/Time

  constructor --id/string --name/string --.created_at:
    super --id=id --name=name

  constructor.from_map map/Map:
    time_string := map["created_at"]
    if not (time_string.ends_with "Z" or time_string.ends_with "+00:00"):
      throw "Unsupported time format: $time_string"
    if time_string.contains ".":
      time_string = time_string[.. time_string.index_of --last "."] + "Z"
    if time_string.ends_with "+00:00":
      time_string = time_string[..time_string.size - 7] + "Z"
    created_at = Time.from_string time_string
    super.from_map map
