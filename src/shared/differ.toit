// Copyright (C) 2022 Toitware ApS. All rights reserved.

abstract class Modification:
  value key/string [--added] [--removed] -> none:
    value key --added=added --removed=removed
        --updated=: | from to |
          removed.call from
          added.call to

  value key/string [--added] [--removed] [--updated] -> none:
    value key --added=added --removed=removed --updated=updated
        --modified=: | modification/UpdatedMap_ |
          updated.call modification.from_ modification.to_

  value key/string [--added] [--removed] [--modified] -> none:
    value key --added=added --removed=removed --modified=modified
        --updated=: | from to |
          removed.call from
          added.call to

  value key/string [--added] [--removed] [--updated] [--modified] -> none:
    // Overridden in subclasses.

  map key/string [--added] [--removed] -> none:
    map key --added=added --removed=removed
        --updated=: | key from to |
          removed.call key from
          added.call key to

  map key/string [--added] [--removed] [--updated] -> none:
    map key --added=added --removed=removed --updated=updated
        --modified=: | key modification/UpdatedMap_ |
          updated.call key modification.from_ modification.to_

  map key/string [--added] [--removed] [--modified] -> none:
    map key --added=added --removed=removed --modified=modified
        --updated=: | key from to |
          removed.call key from
          added.call key to

  map key/string [--added] [--removed] [--updated] [--modified] -> none:
    // Overridden in subclasses.

  static compute --from/Map --to/Map -> Modification?:
    return compute_map_modification_ from to: it

  static stringify modification/Modification? -> string:
    if not modification: return "{ }"
    list := []
    updated_map ::= modification as UpdatedMap_
    updated_map.modifications_.do: | key/string value |
      value_string/string ::= ?
      if value is Added_:
        added ::= value as Added_
        value_string = "+$added.to_"
      else if value is UpdatedMap_:
        value_string = stringify value
      else if value is Updated_:
        updated ::= value as Updated_
        value_string = "$updated.from_->$updated.to_"
      else if value is Removed_:
        removed ::= value as Removed_
        value_string = "~$removed.from_"
      else:
        value_string = "$value"
      list.add "$key: $value_string"
    return "{ $(list.join ", ") }"

// --------------------------------------------------------------------------

abstract class Modification_ extends Modification:
  abstract handle_map_ [--added] [--removed] [--updated] [--modified] -> none
  abstract handle_value_ [--added] [--removed] [--updated] [--modified] -> none

class Added_ extends Modification_:
  to_/any

  constructor .to_:

  handle_value_ [--added] [--removed] [--updated] [--modified] -> none:
    added.call to_

  handle_map_ [--added] [--removed] [--updated] [--modified] -> none:
    if to_ is not Map: return
    to_.do: | key value | added.call key value

class Removed_ extends Modification_:
  from_/any

  constructor .from_:

  handle_value_ [--added] [--removed] [--updated] [--modified] -> none:
    removed.call from_

  handle_map_ [--added] [--removed] [--updated] [--modified] -> none:
    if from_ is not Map: return
    from_.do: | key value | removed.call key value

class Updated_ extends Modification_:
  /// Either $from_ or $to_ isn't a map. Otherwise, the diff
  /// algorithm would have produced an $UpdatedMap_ instance.
  from_/any
  to_/any

  constructor .from_ .to_:

  handle_value_ [--added] [--removed] [--updated] [--modified] -> none:
    updated.call from_ to_

  handle_map_ [--added] [--removed] [--updated] [--modified] -> none:
    /// Since either $from_ or $to_ isn't a map, we treat this
    /// as an addition if we've changed it to a map.
    if to_ is not Map: return
    to_.do: | key value | added.call key value

class UpdatedMap_ extends Modification_:
  from_/Map
  to_/Map
  modifications_/Map  // Map<string, Modification_>

  constructor .from_ .to_ .modifications_:

  value key/string [--added] [--removed] [--updated] [--modified] -> none:
    modification/Modification_? := modifications_.get key
    if not modification: return
    modification.handle_value_ --added=added --removed=removed --updated=updated --modified=modified

  map key/string [--added] [--removed] [--updated] [--modified] -> none:
    modification/Modification_? := modifications_.get key
    if not modification: return
    modification.handle_map_ --added=added --removed=removed --updated=updated --modified=modified

  handle_value_ [--added] [--removed] [--updated] [--modified] -> none:
    modified.call this

  handle_map_ [--added] [--removed] [--updated] [--modified]-> none:
    modifications_.do: | key/string modification/Modification_ |
      modification.handle_value_
          --added    =: added.call key it
          --removed  =: removed.call key it
          --updated  =: | from to | updated.call key from to
          --modified =: modified.call key it

compute_map_modification_ from/Map to/Map [create] -> UpdatedMap_?:
  modifications/Map? := null
  to.do: | to_key/string to_value |
    modification/Modification? := null
    if not from.contains to_key:
      modification = create.call (Added_ to_value)
    else:
      from_value := from.get to_key
      if identical from_value to_value:
        continue.do
      else if from_value is List and to_value is List:
        if list_is_unmodified_ from_value to_value: continue.do
        modification = create.call (Updated_ from_value to_value)
      else if from_value is Map and to_value is Map:
        updated_map ::= compute_map_modification_ from_value to_value create
        if not updated_map: continue.do
        modification = updated_map
      else:
        modification = create.call (Updated_ from_value to_value)
    modifications = modifications or {:}
    modifications[to_key] = modification
  from.do: | from_key/string from_value |
    if to.contains from_key: continue.do
    modification := create.call (Removed_ from_value)
    modifications = modifications or {:}
    modifications[from_key] = modification
  return modifications ? (UpdatedMap_ from to modifications) : null

map_is_unmodified_ from/Map to/Map -> bool:
  compute_map_modification_ from to: return false
  return true

list_is_unmodified_ from/List to/List -> bool:
  size ::= from.size
  if to.size != size: return false
  size.repeat:
    from_element ::= from[it]
    to_element ::= to[it]
    if identical from_element to_element:
      // No change.
    else if from_element is List and to_element is List:
      if not list_is_unmodified_ from_element to_element:
        return false
    else if from_element is Map and to_element is Map:
      if not map_is_unmodified_ from_element to_element:
        return false
    else:
      return false
  return true