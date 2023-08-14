// Copyright (C) 2022 Toitware ApS. All rights reserved.

abstract class Modification:
  /**
  Visits this modification and calls the provided blocks based on
    computed modifications in this instance. If a $key is provided,
    only the modifications to the sub-tree keyed off the $key are
    visited.

  The $added block is called with the value added.

  The $removed block is called with the value removed.

  The $updated block is called with the previous value and the new
    value in that order.

  The $modified block is called with a nested $Modification. This
    can only happen if $key is non-null.
  */
  abstract on-value key/string?=null [--added] [--removed] [--updated] [--modified] -> none

  on-value key/string?=null [--added] [--removed] -> none:
    on-value key --added=added --removed=removed
        --updated=: | from to |
          removed.call from
          added.call to

  on-value key/string?=null [--added] [--removed] [--updated] -> none:
    on-value key --added=added --removed=removed --updated=updated
        --modified=: | modification/UpdatedMap_ |
          updated.call modification.from_ modification.to_

  on-value key/string?=null [--added] [--removed] [--modified] -> none:
    on-value key --added=added --removed=removed --modified=modified
        --updated=: | from to |
          removed.call from
          added.call to

  /**
  Visits this modification treating it as a map. This is equivalent to
    $on-value, but the callbacks all get called with the keys of the map
    entries as the first parameter.

  If this modification changed an entry from a non-map to a map, the
    $added block is called for the new map entries.

  If this modification changed an entry from a map to a non-map, the
    $removed block is called with the old (removed) map entries.
  */
  abstract on-map key/string?=null [--added] [--removed] [--updated] [--modified] -> none

  on-map key/string?=null [--added] [--removed] -> none:
    on-map key --added=added --removed=removed
        --updated=: | key from to |
          removed.call key from
          added.call key to

  on-map key/string?=null [--added] [--removed] [--updated] -> none:
    on-map key --added=added --removed=removed --updated=updated
        --modified=: | key modification/UpdatedMap_ |
          updated.call key modification.from_ modification.to_

  on-map key/string?=null [--added] [--removed] [--modified] -> none:
    on-map key --added=added --removed=removed --modified=modified
        --updated=: | key from to |
          removed.call key from
          added.call key to

  static compute --from/Map --to/Map -> Modification?:
    return compute-map-modification_ from to: null

  static stringify modification/Modification? -> string:
    if not modification: return "{ }"
    list := []
    updated-map ::= modification as UpdatedMap_
    updated-map.modifications_.do: | key/string value |
      value-string/string ::= ?
      if value is Added_:
        added ::= value as Added_
        value-string = "+$added.to_"
      else if value is UpdatedMap_:
        value-string = stringify value
      else if value is Updated_:
        updated ::= value as Updated_
        value-string = "$updated.from_->$updated.to_"
      else if value is Removed_:
        removed ::= value as Removed_
        value-string = "~$removed.from_"
      else:
        value-string = "$value"
      list.add "$key: $value-string"
    return "{ $(list.join ", ") }"

/**
Compares the JSON objects $a and $b and returns
  whether they are equal.

The comparison is done deeply, and nested objects are compared
  recursively.
*/
json-equals a/any b/any -> bool:
  if identical a b: return true
  if a is Map and b is Map:
    if a.size != b.size: return false
    a.do: | key value |
      if not b.contains key: return false
      if not json-equals value b[key]: return false
    return true
  else if a is List and b is List:
    if a.size != b.size: return false
    a.size.repeat: | i |
      if not json-equals a[i] b[i]: return false
    return true
  else:
    return false

// --------------------------------------------------------------------------

abstract class Modification_ extends Modification:
  on-value key/string?=null [--added] [--removed] [--updated] [--modified] -> none:
    unreachable  // Overriden in all exposed subclasses.

  on-map key/string?=null [--added] [--removed] [--updated] [--modified] -> none:
    unreachable  // Overriden in all exposed subclasses.

  abstract visit-as-value_ [--added] [--removed] [--updated] [--modified] -> none
  abstract visit-as-map_ [--added] [--removed] [--updated] [--modified] -> none

class Added_ extends Modification_:
  to_/any

  constructor .to_:

  visit-as-value_ [--added] [--removed] [--updated] [--modified] -> none:
    added.call to_

  visit-as-map_ [--added] [--removed] [--updated] [--modified] -> none:
    if to_ is not Map: return
    to_.do: | key value | added.call key value

class Removed_ extends Modification_:
  from_/any

  constructor .from_:

  visit-as-value_ [--added] [--removed] [--updated] [--modified] -> none:
    removed.call from_

  visit-as-map_ [--added] [--removed] [--updated] [--modified] -> none:
    if from_ is not Map: return
    from_.do: | key value | removed.call key value

class Updated_ extends Modification_:
  /// Either $from_ or $to_ isn't a map. Otherwise, the diff
  /// algorithm would have produced an $UpdatedMap_ instance.
  from_/any
  to_/any

  constructor .from_ .to_:

  visit-as-value_ [--added] [--removed] [--updated] [--modified] -> none:
    updated.call from_ to_

  visit-as-map_ [--added] [--removed] [--updated] [--modified] -> none:
    /// Since either $from_ or $to_ isn't a map, we treat this
    /// as an addition if we've changed it to a map -- or a
    /// removal if we changed it from a map.
    if to_ is Map:
      to_.do: | key value | added.call key value
    else if from_ is Map:
      from_.do: | key value | removed.call key value

class UpdatedMap_ extends Modification_:
  from_/Map
  to_/Map
  modifications_/Map  // Map<string, Modification_>

  constructor .from_ .to_ .modifications_:

  on-value key/string?=null [--added] [--removed] [--updated] [--modified] -> none:
    modification/Modification_? := this
    if key:
      modification = modifications_.get key
      if not modification: return
    modification.visit-as-value_ --added=added --removed=removed --updated=updated --modified=modified

  on-map key/string?=null [--added] [--removed] [--updated] [--modified] -> none:
    modification/Modification_? := this
    if key:
      modification = modifications_.get key
      if not modification: return
    modification.visit-as-map_ --added=added --removed=removed --updated=updated --modified=modified

  visit-as-value_ [--added] [--removed] [--updated] [--modified] -> none:
    modified.call this

  visit-as-map_ [--added] [--removed] [--updated] [--modified]-> none:
    modifications_.do: | key/string modification/Modification_ |
      modification.visit-as-value_
          --added    =: added.call key it
          --removed  =: removed.call key it
          --updated  =: | from to | updated.call key from to
          --modified =: modified.call key it

compute-map-modification_ from/Map to/Map [modified] -> UpdatedMap_?:
  modifications/Map? := null
  to.do: | to-key/string to-value |
    modification/Modification? := null
    if not from.contains to-key:
      modified.call
      modification = Added_ to-value
    else:
      from-value := from.get to-key
      if identical from-value to-value:
        continue.do
      else if from-value is List and to-value is List:
        if json-equals from-value to-value: continue.do
        modified.call
        modification = Updated_ from-value to-value
      else if from-value is Map and to-value is Map:
        updated-map ::= compute-map-modification_ from-value to-value modified
        if not updated-map: continue.do
        modification = updated-map
      else:
        modified.call
        modification = Updated_ from-value to-value
    modifications = modifications or {:}
    modifications[to-key] = modification
  from.do: | from-key/string from-value |
    if to.contains from-key: continue.do
    modified.call
    modification := Removed_ from-value
    modifications = modifications or {:}
    modifications[from-key] = modification
  return modifications ? (UpdatedMap_ from to modifications) : null
