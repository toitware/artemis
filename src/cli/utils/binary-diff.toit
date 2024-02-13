// Copyright (C) 2020 Toitware ApS. All rights reserved.

import binary show LITTLE-ENDIAN
import crypto.adler32 show *
import crypto.sha256 show *
import host.pipe
import writer

import ...shared.utils.patch-format

// Smaller numbers take longer, but get smaller diffs.
SECTION-SIZE_ ::= 16

/// Create a binary diff from $old-bytes to $new-bytes, and write it
/// to the open file, $fd.  Returns the size of the diff file in bytes.
diff old-bytes/OldData new-bytes/ByteArray fd total-new-bytes=new-bytes.size --fast/bool --with-header=true --with-footer=true --with-checksums=true -> int:
  pages := NewOldOffsets old-bytes new-bytes old-bytes.sections SECTION-SIZE_ --fast=fast

  bdiff-size := 0

  end-state := diff-files old-bytes new-bytes pages fast total-new-bytes --with-header=with-header --with-checksums=with-checksums:
    // Do not print anything.
    null

  writer := Writer_ new-bytes
  bdiff-size += writer.write-diff fd end-state --with-footer=with-footer

  return bdiff-size

literal-block new-bytes/ByteArray fd --total-new-bytes/int?=null --with-footer=false -> int:
  initial-state := total-new-bytes
      ? InitialState_ (OldData #[] 0 0) new-bytes total-new-bytes --with-header=true
      : InitialState_.no-old-bytes new-bytes --with-header=false

  head/Action := initial-state

  head = MoveCursor_ head 0 true  // Switch to byte oriented mode.

  start-of-section := 0
  scanning-repeated-bytes := false
  // The loop has two states - counting repeated bytes and literal non-repeated data.
  assert: head.byte-oriented
  for i := 0; i <= new-bytes.size; i++:
    if scanning-repeated-bytes:
      if i == new-bytes.size or not all-same_ new-bytes[i - 1..i + 1]:
        head = RepeatedBytes_ head --repeats=(i - start-of-section) --value=new-bytes[i - 1]
        scanning-repeated-bytes = false
        start-of-section = i
    if not scanning-repeated-bytes:
      if i == new-bytes.size or (i < new-bytes.size - 8 and all-same_ new-bytes[i..i + 8]):
        if start-of-section != i:
          head = Literal_.literal-section head (i - start-of-section)
        start-of-section = i
        scanning-repeated-bytes = true

  assert: head.bits-spent & 7 == 0

  writer := Writer_ new-bytes

  bdiff-size := writer.write-diff fd head --with-footer=with-footer

  return bdiff-size

all-same_ byte-array/ByteArray -> bool:
  value := byte-array[0]
  byte-array.size.repeat:
    if value != byte-array[it]: return false
  return true

new-checksum-block new-bytes/ByteArray fd checksum/ByteArray --with-header=true -> int:
  initial-state := InitialState_.no-old-bytes new-bytes --with-header
  checksum-action := NewChecksumAction_ initial-state --checksum=checksum

  assert: checksum-action.bits-spent & 7 == 0

  writer := Writer_ new-bytes

  bdiff-size := writer.write-diff fd checksum-action --with-footer=false

  return bdiff-size

class BitSequence_:
  // First we will output these bits.
  bits/int
  // This is the number of bits in the above int that are output.
  number-of-bits/int
  // Once we have output the initial bits, we output this byte array.
  byte-array/ByteArray? := null
  byte-array-start/int := 0
  byte-array-count/int := 0

  constructor .number-of-bits .bits:

  constructor .number-of-bits .bits .byte-array .byte-array-start=0 .byte-array-count=byte-array.size:

  static size-field_ size-in-bits [block]:
    // 2 bit field gives the size of the size field, 6, 14, 22, or 30 bits.
    for i := 6; i <= 30; i += 8:
      if size-in-bits < (1 << i):
        block.call (i / 8) i
        return
    throw "Metadata size too large"

  static empty-byte-array_ := ByteArray 0

  // Specialized constructor used by the Metadata actions.
  // Emits the 16 bit metadata code, then the size, then the
  // byte array.
  constructor.metadata code/int --ignorable/bool data/ByteArray=empty-byte-array_:
    number-of-bits = 16
    assert: 0 <= code <= 0x7f
    bits = (ignorable ? IGNORABLE-METADATA : NON-IGNORABLE-METADATA) + code

    // Append variable sized big-endian size field, in bits.
    size := data.size * 8
    size-field-size := 0
    size-code := 0
    size-field_ size: | size-code size-field-size |
      bits <<= 2
      bits |= size-code
      bits <<= size-field-size
      bits |= size
      number-of-bits += 2 + size-field-size

    byte-array = data
    byte-array-count = data.size

/// Immutable diff table structure.  Always returns a new
/// one rather than mutating it.  This is used for creating
/// diffs, but a mutable version is more efficient for
/// patching.
class DiffTable_:
  diffs_/List := List DIFF-TABLE-SIZE: 0

  constructor:

  constructor.private_ .diffs_:

  operator [] index -> int:
    return diffs_[index]

  /// Puts a new value in the middle and shifts the later items down
  /// by one.
  insert value/int -> DiffTable_:
    pos := DIFF-TABLE-INSERTION
    new-diffs := List DIFF-TABLE-SIZE:
      it <= pos ? diffs_[it] : diffs_[it - 1]
    new-diffs[pos] = value
    return DiffTable_.private_ new-diffs

  make-entry-zero-zero -> DiffTable_:
    if diffs_[0] == 0: return this
    zero-found := false
    new-diffs := List DIFF-TABLE-SIZE:
      result := zero-found ? diffs_[it] : (it == 0 ? 0 : diffs_[it - 1])
      if diffs_[it] == 0:
        zero-found = true
      result
    return DiffTable_.private_ new-diffs

  /// Find the position of a number in the table or return null if
  /// it's not there.
  index-of value/int? -> int?:
    if not value: return null
    diffs_.size.repeat: if diffs_[it] == value: return it
    return null

  /// When an item in the table is used, it moves half as close to
  /// the start, and other items are moved down.
  promote index/int -> DiffTable_:
    if index == 0: return this
    new-position := index / 2
    new-diffs := List DIFF-TABLE-SIZE:
      (it < new-position or it > index) ? diffs_[it] : it == new-position ? diffs_[index] : diffs_[it - 1]
    return DiffTable_.private_ new-diffs

class OldData:
  bytes/ByteArray
  ignore-from/int
  ignore-to/int
  sections/Map? := null

  constructor .bytes .ignore-from=0 .ignore-to=0:
    if bytes.size != 0:
      sections = Section.get-sections this SECTION-SIZE_

  size -> int:
    return bytes.size

  valid index/int length=1 -> bool:
    assert: length > 0
    if index < 0: return false
    if index + length > size: return false
    if ignore-to <= index: return true
    if index + length <= ignore-from: return true
    return false

  operator [] index/int:
    assert: not ignore-from <= index < ignore-to
    return bytes[index]

  read-int32 index/int:
    assert: not ignore-from - 4 < index < ignore-to
    return LITTLE-ENDIAN.read-int bytes 4 index

abstract class Action:
  old-bytes/OldData     // Same for all actions.
  new-bytes/ByteArray   // Same for all actions.
  predecessor/Action?   // The chain back in time of immutable actions.
  diff-table/DiffTable_  // The following values represent the situation after this action.
  old-position/int
  new-position/int
  bits-spent/int
  byte-oriented/bool
  years-past-its-prime/int := 0
  data-width /int

  constructor.private_ .predecessor .diff-table .old-position .new-position .bits-spent:
    byte-oriented = predecessor.byte-oriented
    old-bytes = predecessor.old-bytes
    new-bytes = predecessor.new-bytes
    years-past-its-prime = predecessor.years-past-its-prime + predecessor.data-width
    data-width = byte-oriented ? 1 : 4

  constructor.private_ .predecessor .diff-table .old-position .new-position .bits-spent .byte-oriented:
    old-bytes = predecessor.old-bytes
    new-bytes = predecessor.new-bytes
    years-past-its-prime = predecessor.years-past-its-prime + predecessor.data-width
    data-width = byte-oriented ? 1 : 4

  constructor.private_ .predecessor .diff-table .old-position .new-position .bits-spent .byte-oriented .old-bytes .new-bytes:
    data-width = byte-oriented ? 1 : 4

  set-its-the-best -> none:
    years-past-its-prime = 0

  past-its-prime -> bool:
    return years-past-its-prime > 500

  // *** Methods for the ComparableSet_ ***
  abstract comparable-hash-code -> int
  abstract compare other -> bool
  worse-than other -> bool:
    return other.bits-spent < bits-spent

  // Compare that fits with ordered_diff_hash.
  base-compare_ other -> bool:
    if other.old-position != old-position: return false
    if other.byte-oriented != byte-oriented: return false
    (DIFF-TABLE-INSERTION + 1).repeat:
      if diff-table[it] != other.diff-table[it]: return false
    return true

  // Hash that fits with base_compare_
  ordered-diff-hash_ seed -> int:
    hash := seed
    if byte-oriented: hash += 57
    (DIFF-TABLE-INSERTION + 1).repeat:
      hash = ((hash * 11) + diff-table[it]) & 0x1fff_ffff
    return (hash + old-position * 13) & 0x1fff_ffff

  // *** Methods for the RoughlyComparableSet_ ***
  abstract rough-hash-code -> int
  abstract roughly-equals other -> bool
  roughly-worse-than other -> bool:
    return other.bits-spent < bits-spent

  // Compare that fits with unordered_diff_hash.
  unordered-compare_ other -> bool:
    if other.byte-oriented != byte-oriented: return false
    if other.old-position != old-position: return false
    if byte-oriented:
      assert: diff-table[0] == 0
      if other.diff-table[1] != diff-table[1]: return false
    else:
      if other.diff-table[0] != diff-table[0]: return false
    return true

  // Hash that fits with unordered_compare_.  Seed is a per-class constant.
  unordered-diff-hash_ seed -> int:
    sum := seed
    product := seed | 1
    eor := 0
    diff := diff-table[byte-oriented ? 1 : 0]
    sum += diff
    if diff == 0:
      product *= 941
    else:
      product *= diff
    product &= 0xfffff
    eor ^= diff
    if byte-oriented: sum += 57
    return (941 + sum + product + eor) & 0x1fff_ffff

  diff-to-int_ value/int?:
    if byte-oriented:
      integer := value & 0xff
      if integer >= 0x80: integer -= 0x100 // Treat as signed byte.
      return integer
    // Treat as signed 32 bit value.
    value &= 0xffff_ffff
    if value >= 0x8000_0000: value -= 0x1_0000_0000
    if 0 - 0x8000 <= value <= 0x7fff: return value
    return null

  old-data -> int:
    if byte-oriented:
      return old-bytes[old-position]
    return old-bytes.read-int32 old-position

  new-data -> int:
    if byte-oriented:
      return new-bytes[new-position]
    return LITTLE-ENDIAN.read-int new-bytes 4 new-position

  add-data new-position/int fast/bool -> List:
    wanted-diff := null

    if not byte-oriented:
      assert: old-position.is-aligned 4
      assert: new-position.is-aligned 4

    if old-bytes.valid old-position data-width:
      wanted-diff = diff-to-int_ new-data - old-data
      // If a diff table entry fits, it's the best move.
      index := diff-table.index-of wanted-diff
      if index:
        return [create-diff_ new-data index]
    // No existing diff table entry fits.  We can either overwrite a
    // byte/word or add a new diff table entry.
    result := []
    if wanted-diff and not fast:
      worth := not byte-oriented
      if byte-oriented and old-bytes.valid old-position 17:
        16.repeat:
          ahead := it + 1
          if old-position + ahead < old-bytes.size and new-position + ahead < new-bytes.size:
            if (old-bytes[old-position + ahead] + wanted-diff) & 0xff == new-bytes[new-position + ahead]:
              worth = true
      if worth:
        result.add
          NewDiffEntry_ this new-data
    result.add
      Literal_ this new-data new-position
    return result

  static EMPTY ::= List 0

  move-cursor new-to-old/int new-position/int --fast/bool -> List:
    current-new-to-old := old-position - new-position
    diff := new-to-old - current-new-to-old
    possible-old-position := new-position + new-to-old
    if not old-bytes.valid possible-old-position 8: return EMPTY
    if new-position >= new-bytes.size - 8: return EMPTY
    match-count := 0
    o := LITTLE-ENDIAN.int64 old-bytes.bytes possible-old-position
    n := LITTLE-ENDIAN.int64 new-bytes new-position
    match-count = (int-vector-equals o n).population-count
    if match-count < 5: return EMPTY
    result := []
    if not byte-oriented:
      // Currently word oriented.
      if new-to-old.is-aligned 4:
        assert: current-new-to-old.is-aligned 4
        if diff != 0:
          result.add
            MoveCursor_ this diff false  // Word oriented.
      if not fast:
        result.add
          MoveCursor_ this diff true  // Byte oriented.
    else:
      // Currently byte oriented.
      if new-position.is-aligned 4 and new-to-old.is-aligned 4:
        result.add
          MoveCursor_ this diff false // Word oriented.
      if diff != 0:
        result.add
          MoveCursor_ this diff true // Byte oriented.
    return result

  create-diff_ data/int index/int:
    if index == 0:
      return BuildingDiffZero_ this data
    // A non-zero diff can't be promoted to the zero position in
    // byte mode.
    new-diff-table := (index == 1 and byte-oriented) ? diff-table : (diff-table.promote index)
    return DiffTableAction_ this new-diff-table data index

  short-string -> string:
    return stringify

  old-representation_ bytes/int -> string:
    old := ""
    pos := old-position - bytes
    (min 8 bytes).repeat:
      old += "$(%02x old-bytes[pos + it]) "
    if bytes > 8:
      old += "..."
    return "$(%-30s old) $(%8d pos)"

  new-representation_ bytes/int -> string:
    new := ""
    pos := new-position - bytes
    (min 8 bytes).repeat:
      new += "$(%02x new-bytes[pos + it]) "
    if bytes > 8:
      new += "..."
    return "$(%-30s new) $(%8d pos)"

/// Returns a non-negative number as a series of bytes in big-endian order.
/// Since the size of the data attached to the metadata is given, we can
///   use 8 bit numbers, 16 bit number, 24 bit numbers etc.
metadata-number_ x -> ByteArray:
  assert: x >= 0
  little-endian := []
  while x != 0:
    little-endian.add x & 0xff
    x >>= 8
  return ByteArray little-endian.size: little-endian[little-endian.size - 1 - it]

class InitialState_ extends Action:
  with-header_ ::= ?
  // Total size of the result.  This may be after some binary patches have been
  // concatenated, so it may not reflect the size of the current block being
  // diffed.
  total-new-bytes_/int

  constructor old-bytes/OldData new-bytes/ByteArray .total-new-bytes_=new-bytes.size --with-header=true:
    with-header_ = with-header
    super.private_ null DiffTable_ 0 0 0 false old-bytes new-bytes

  constructor.no-old-bytes bytes/ByteArray --with-header=false:
    with-header_ = with-header
    total-new-bytes_ = 0
    dummy-old-data := OldData (ByteArray 0) 0 0
    super.private_ null DiffTable_ 0 0 0 false dummy-old-data bytes

  emit-bits optional-pad/int -> List:
    result := []
    if with-header_:
      magic := #[0x70, 0x17, 0xd1, 0xff]  // 0x7017d1ff.
      result.add
        BitSequence_.metadata 'M' --ignorable=false magic
      if total-new-bytes_ != 0:
        result.add
          BitSequence_.metadata 'n' --ignorable=true (metadata-number_ total-new-bytes_)
    else:
      // Add state reset action instead of header so that sections can be
      // concatenated.
      result.add
        BitSequence_.metadata 'R' --ignorable=false
    return result

  stringify -> string:
    return "Initial State"

  short-string -> string:
    return "Initial    $(bits-spent) bits, offset: $(old-position - new-position)"

  comparable-hash-code -> int:
    return 123

  compare other -> bool:
    return false

  rough-hash-code -> int:
    return 123

  roughly-equals other -> bool:
    return false

class RepeatedBytes_ extends Action:
  value /int
  repeats /int
  constructor predecessor/Action --.repeats --.value=0:
    super.private_ predecessor predecessor.diff-table predecessor.old-position
        predecessor.new-position + repeats
        predecessor.bits-spent + 24 + (value == 0 ? 0 : 8)
    if not byte-oriented: assert: repeats % 4 == 0

  emit-bits optional-pad/int -> List:
    rep := byte-oriented ? repeats : repeats / 4
    if value == 0:
      return [BitSequence_.metadata 'Z' --ignorable=false (metadata-number_ rep)]
    else:
      return [BitSequence_.metadata 'L' --ignorable=false (#[value] + (metadata-number_ rep))]

  stringify -> string:
    return "Repeated, value=$value, repeats=$repeats"

  short-string -> string:
    return "Repeated, value=$value, repeats=$repeats"

  comparable-hash-code -> int:
    return (value + 1) * repeats

  compare other -> bool:
    if other is not RepeatedBytes_: return false
    if other.value != value: return false
    if other.repeats != repeats: return false
    return base-compare_ other

  rough-hash-code -> int:
    return (value + 1) * repeats

  roughly-equals other -> bool:
    return compare other

class SpecialAction_ extends Action:
  hash-code_ := 0
  constructor predecessor/Action bits-spent/int=predecessor.bits-spent:
    super.private_ predecessor predecessor.diff-table predecessor.old-position predecessor.new-position bits-spent
    hash-code_ = random 0 1_000_000_000

  comparable-hash-code -> int:
    return hash-code_

  compare other -> bool:
    return identical this other

  rough-hash-code -> int:
    return hash-code_

  roughly-equals other -> bool:
    return identical this other

class OldChecksumAction_ extends SpecialAction_:
  old-data_/OldData ::= ?

  constructor predecessor/Action .old-data_:
    super predecessor

  emit-bits optional-pad/int -> List:
    result := []
    if old-data_.ignore-from > 0:
      old-sha := sha256 old-data_.bytes 0 old-data_.ignore-from
      payload := create-old-sha-payload_ old-sha 0 old-data_.ignore-from
      result.add
        BitSequence_.metadata 'S' --ignorable=true payload
    if old-data_.ignore-to < old-data_.size:
      old-sha := sha256 old-data_.bytes old-data_.ignore-to old-data_.size
      payload := create-old-sha-payload_ old-sha old-data_.ignore-to old-data_.size - old-data_.ignore-to
      result.add
        BitSequence_.metadata 'S' --ignorable=true payload
    return result

  create-old-sha-payload_ sha/ByteArray from/int size/int -> ByteArray:
    old-payload := ByteArray 6 + sha.size: | index |
      if index < 3: continue.ByteArray (from >> (16 - 8 * index)) & 0xff
      index -= 3
      if index < 3: continue.ByteArray (size >> (16 - 8 * index)) & 0xff
      index -= 3
      continue.ByteArray sha[index]
    return old-payload

  stringify -> string:
    return "Old checksum"

class NewChecksumAction_ extends SpecialAction_:
  checksum := null

  constructor predecessor/Action --.checksum=null:
    super predecessor

  emit-bits optional-pad/int -> List:
    assert: checksum.size == 32
    return [BitSequence_.metadata 's' --ignorable=true checksum]

  stringify -> string:
    return "New checksum"

class EndAction_ extends SpecialAction_:
  constructor predecessor/Action:
    super predecessor

  emit-bits optional-pad/int -> List:
    return [BitSequence_.metadata 'E' --ignorable=false]

  short-string -> string:
    return "End        $(bits-spent - predecessor.bits-spent) bits, offset: $(old-position - new-position)"

/// Used to pad output up to a whole number of bytes.  If we were already
/// aligned it takes 0 bits, otherwise 17-23 bits.
class PadAction_ extends SpecialAction_:
  constructor predecessor/Action:
    super predecessor

  emit-bits pad-bits/int -> List:
    result := []
    emit-driver pad-bits: | bits bit-pattern |
      result.add
        BitSequence_ bits bit-pattern
    return result

  static emit-driver pad-bits [block] -> none:
    if pad-bits == 0: return
    assert: 0 < pad-bits <= 7
    block.call
      16 + pad-bits
      // We use the code that moves the old-data cursor by 0 bytes.
      0b1111_1110_1000_0000 << pad-bits

  short-string -> string:
    return "Pad        , offset: $(old-position - new-position)"

class MoveCursor_ extends Action:
  step/int

  constructor predecessor/Action .step/int byte-oriented/bool:
    extra-bits := 8
    if step.abs != 1: extra-bits = 16
    if not -128 <= step <= 127: extra-bits = 32
    if predecessor.byte-oriented != byte-oriented: extra-bits = 32
    if step == 0 and predecessor.byte-oriented != byte-oriented: extra-bits = 8
    assert: predecessor.old-position + step >= 0
    new-diff-table := predecessor.diff-table
    if (not predecessor.byte-oriented) and byte-oriented:
      // In byte oriented mode the first entry in the diff table is always
      // zero, but this is not the case in word oriented mode.
      new-diff-table = new-diff-table.make-entry-zero-zero
    super.private_
      predecessor
      new-diff-table
      predecessor.old-position + step
      predecessor.new-position
      predecessor.bits-spent + extra-bits
      byte-oriented

  emit-bits optional-pad/int -> List:
    if step == 0 and predecessor.byte-oriented != byte-oriented:
      return [BitSequence_ 8 0b1111_1111]
    in-byte-range := 0 - 0x80 <= step <= 0x7f
    if predecessor.byte-oriented != byte-oriented or not in-byte-range:
      location := ByteArray 3: (old-position >> (8 * (2 - it))) & 0xff
      flag := byte-oriented ? 1 : 0
      return [BitSequence_ 8 0b1110_1110 + flag location]
    if step.abs == 1:
      if step == 1:
        return [BitSequence_ 8 0b1111_1101]
      else:
        return [BitSequence_ 8 0b1111_1100]
    assert: in-byte-range
    return [BitSequence_ 16 0b1111_1110_0000_0000 + ((step + 0x80) & 0xff)]

  comparable-hash-code -> int:
    hash := ordered-diff-hash_ 103
    // Don't use the step for the hash - it's where we land, not how
    // we got there.
    return hash

  compare other/Action -> bool:
    if other is not MoveCursor_: return false
    return base-compare_ other

  rough-hash-code -> int:
    hash := unordered-diff-hash_ 103
    return hash

  roughly-equals other -> bool:
    if other is not MoveCursor_: return false
    return unordered-compare_ other

  stringify -> string:
    entries := ""
    DIFF-TABLE-SIZE.repeat:
      entries += "$diff-table[it], "
    return "$(byte-oriented ? "B" : "W") Move cursor, old_position $old-position, $bits-spent bits spent, $entries"

  short-string -> string:
    return "Offset   $(byte-oriented ? "B" : "W") $(bits-spent - predecessor.bits-spent) bits, offset: $(old-position - new-position)"

class NewDiffEntry_ extends Action:
  diff/int

  constructor predecessor/Action data/int:
    wanted-diff := predecessor.diff-to-int_ data - predecessor.old-data
    assert: wanted-diff
    diff = wanted-diff
    extra-bits := (one-byte_ wanted-diff predecessor.byte-oriented) ? 14 : 22
    super.private_
      predecessor
      predecessor.diff-table.insert wanted-diff
      predecessor.old-position + predecessor.data-width
      predecessor.new-position + predecessor.data-width
      predecessor.bits-spent + extra-bits

  emit-bits optional-pad/int -> List:
    byte := one-byte_ diff byte-oriented
    if byte:
      return [BitSequence_ 14 0b1111_00_0000_0000 + byte]
    assert: 0 - 0x8000 <= diff <= 0x7fff
    return [BitSequence_ 22 0b1111_01_0000_0000_0000_0000 + diff + 0x8000]

  /// If the difference can be represented as a signed 8 bit value, then
  /// returns that difference, biased by 0x80.  Otherwise returns null.
  static one-byte_ diff/int byte-oriented/bool -> int?:
    if byte-oriented:
      masked := diff & 0xff
      signed := masked >= 0x80  ? masked - 0x100 : masked
      return signed + 0x80
    if 0 - 0x80 <= diff <= 0x7f:
      return diff + 0x80
    return null

  stringify -> string:
    entries := ""
    DIFF-TABLE-SIZE.repeat:
      entries += "$diff-table[it], "
    return "$(byte-oriented ? "B" : "W") New diff, $bits-spent bits spent, $entries"// $name from $predecessor.name"

  short-string -> string:
    old := old-representation_ data-width
    new := new-representation_ data-width
    line := "New diff $(byte-oriented ? "B" : "W") $(bits-spent - predecessor.bits-spent) bits"
    return "$(%30s line) $old\n$(%30s   "") $new"

  comparable-hash-code -> int:
    hash := ordered-diff-hash_ 41
    return hash

  compare other -> bool:
    if other is not NewDiffEntry_: return false
    return base-compare_ other

  rough-hash-code -> int:
    hash := unordered-diff-hash_ 41
    return hash

  roughly-equals other -> bool:
    if other is not NewDiffEntry_: return false
    return unordered-compare_ other

class DiffTableAction_ extends Action:
  index/int

  emit-bits optional-pad/int -> List:
    if index == 1: return [BitSequence_ 3 0b100]
    if index <= 3: return [BitSequence_ 4 0b1010 + index - 2]
    if index <= 7: return [BitSequence_ 5 0b11000 + index - 4]
    return [BitSequence_ 8 0b1110_0000 + index - 8]

  constructor predecessor/Action new-diff-table/DiffTable_ data/int .index:
    assert: index != null
    assert: index != 0
    extra-bits := 0
    if index == 1: extra-bits = 3
    else if index <= 3: extra-bits = 4
    else if index <= 7: extra-bits = 5
    else: extra-bits = 8
    super.private_
      predecessor
      new-diff-table
      predecessor.old-position + predecessor.data-width
      predecessor.new-position + predecessor.data-width
      predecessor.bits-spent + extra-bits

  stringify -> string:
    entries := ""
    DIFF-TABLE-SIZE.repeat:
      entries += "$diff-table[it], "
    return "$(byte-oriented ? "B" : "W") Diff at $index by $diff-table[index], $bits-spent bits spent, $entries"// $name from $predecessor.name"

  short-string -> string:
    old := old-representation_ data-width
    new := new-representation_ data-width
    line := "Diff   $(byte-oriented ? "B" : "W") $(bits-spent - predecessor.bits-spent) bits, index: $index"
    return "$(%30s line) $old\n$(%30s   "") $new"

  comparable-hash-code -> int:
    hash := ordered-diff-hash_ index
    return hash

  compare other -> bool:
    if other is not DiffTableAction_: return false
    if other.index != index: return false
    return base-compare_ other

  rough-hash-code -> int:
    hash := unordered-diff-hash_ 71
    return hash

  roughly-equals other -> bool:
    if other is not DiffTableAction_: return false
    return unordered-compare_ other

/// We are adding literal data.
class Literal_ extends Action:
  byte-count/int
  new-position_/int

  constructor predecessor/Action data/int .new-position_/int:
    byte-count = predecessor.data-width
    super.private_
      predecessor
      predecessor.diff-table
      predecessor.old-position + predecessor.data-width  // Overwrite, so we still step forwards.
      predecessor.new-position + predecessor.data-width  // Overwrite, so we still step forwards.
      predecessor.bits-spent + 8 + 8 * predecessor.data-width

  constructor.literal-section predecessor/Action size/int:
    new-position_ = predecessor.new-position
    byte-count = size
    if not predecessor.byte-oriented and not size.is-aligned 4: throw "Literal section must be a multiple of 4"
    new-bits-spent := predecessor.bits-spent
    emit-driver byte-count 4: | bits _ _ length |
      new-bits-spent += bits + length * 8
    super.private_
      predecessor
      predecessor.diff-table
      predecessor.old-position + byte-count
      predecessor.new-position + byte-count
      new-bits-spent

  constructor.private_ predecessor/Literal_:
    byte-count = predecessor.byte-count + predecessor.data-width
    new-bits-spent := predecessor.predecessor.bits-spent
    emit-driver byte-count predecessor.data-width: | bits _ _ length |
      new-bits-spent += bits + length * 8
    new-position_ = predecessor.new-position_
    super.private_
      predecessor.predecessor  // Chop previous action out of chain.
      predecessor.diff-table
      predecessor.old-position + predecessor.data-width  // Overwrite, so we still step forwards.
      predecessor.new-position + predecessor.data-width  // Overwrite, so we still step forwards.
      new-bits-spent

  emit-bits optional-pad/int -> List:
    result := []
    if byte-count >= 64:
      // If we have a large-ish number of literal bytes it is worth spending
      // 17-23 bits to byte align first - this ensures that we can use
      // memcpy-like operations when patching.
      PadAction_.emit-driver optional-pad: | bits bit-pattern |
        result.add
          BitSequence_ bits bit-pattern

    emit-driver byte-count data-width: | bits bit-pattern from length |
      result.add
        BitSequence_ bits bit-pattern new-bytes new-position_+from length
    return result

  static emit-driver byte-count/int data-width/int [block]-> none:
    datum-count := byte-count / data-width
    offset := 0
    while datum-count > 6:
      chunk := min 262 datum-count
      block.call 16 0b1111_1011_0000_0000 + chunk - 7 offset chunk * data-width
      offset += chunk * data-width
      datum-count -= chunk
    while datum-count > 0:
      chunk := min 3 datum-count
      block.call 8 0b11111000 + chunk - 1 offset chunk * data-width
      offset += chunk * data-width
      datum-count -= chunk

  add-data new-position/int fast/bool -> List:
    assert: new-position == new-position_ + byte-count
    result := super new-position fast
    extended := Literal_.private_ this
    extended.years-past-its-prime = years-past-its-prime + data-width
    if result.size != 0 and result[result.size - 1] is Literal_:
      result[result.size - 1] = extended
    else:
      result.add extended
    return result

  stringify -> string:
    entries := ""
    DIFF-TABLE-SIZE.repeat:
      entries += "$diff-table[it], "
    return "$(byte-oriented ? "B" : "W") Literal_ length $byte-count, $bits-spent bits spent, $entries"// $name from $predecessor.name"

  short-string -> string:
    old := old-representation_ byte-count
    new := new-representation_ byte-count
    line := "Literl $(byte-oriented ? "B" : "W") $(bits-spent - predecessor.bits-spent) bits, bytes: $byte-count"
    return "$(%30s line) $old\n$(%30s   "") $new"

  byte-count-category_ -> int:
    if byte-count < 5: return byte-count
    if byte-count < 10: return 5
    if byte-count < 200: return 10
    return 200

  comparable-hash-code -> int:
    hash := ordered-diff-hash_ 521
    hash += byte-count-category_ * 53
    hash &= 0x1fff_ffff
    return hash

  compare other -> bool:
    if other is not Literal_: return false
    if other.byte-count-category_ != byte-count-category_: return false
    return base-compare_ other

  rough-hash-code -> int:
    hash := unordered-diff-hash_ 521
    hash += byte-count-category_ * 53
    hash &= 0x1fff_ffff
    return hash

  roughly-equals other -> bool:
    if other is not Literal_: return false
    if other.byte-count-category_ != byte-count-category_: return false
    return unordered-compare_ other

/// We are building up a sequence of matches of entry 0
/// in the diff table.
class BuildingDiffZero_ extends Action:
  data-count/int

  constructor predecessor/Action data/int:
    data-count = 1
    super.private_
      predecessor
      predecessor.diff-table
      predecessor.old-position + predecessor.data-width
      predecessor.new-position + predecessor.data-width
      predecessor.bits-spent + 2

  constructor.private_ predecessor diff-table old-position new-position bits-spent .data-count:
    super.private_ predecessor diff-table old-position new-position bits-spent

  emit-bits optional-pad/int -> List:
    list := []
    emit-driver data-count: | bit-count pattern argument |
      list.add
        BitSequence_ bit-count pattern + argument
    return list

  //  2, 0b00, 0, 1,        // 00          Diff index 0 1.
  //  2, 0b01, 2, 3,        // 01xx        Diff index 0 3-5.
  //  4, 0b0111, 4, 11,     // 0111xxxx    Diff index 0 11-23.
  //  8, 0b01111101, 8, 47, // 01111101    Diff index 0 47-302.
  //  8, 0b01111110, 16, 255, // 01111110  Diff index 0 255-65790.
  static emit-driver count/int [block]-> none:
    while count > 302:
      increment := min 65790 count
      block.call 24 0b0111_1110_0000_0000_0000_0000 increment - 255
      count -= increment
    while count >= 47:
      increment := min 302 count
      block.call 16 0b0111_1101_0000_0000 increment - 47
      count -= increment
    while count >= 11:
      increment := min 23 count
      block.call 8 0b0111_0000 increment - 11
      count -= increment
    while count >= 3:
      increment := min 5 count
      block.call 4 0b0100 increment - 3
      count -= increment
    while count >= 1:
      block.call 2 0b00 0
      count--

  stringify -> string:
    entries := ""
    DIFF-TABLE-SIZE.repeat:
      entries += "$diff-table[it], "
    return "$(byte-oriented ? "B" : "W") Zero diff, $data-count bytes, $bits-spent bits spent, age $years-past-its-prime, $entries"// $name from $predecessor.name"

  short-string -> string:
    old := old-representation_ data-count * data-width
    new := new-representation_ data-count * data-width
    line := "0 diff $(byte-oriented ? "B" : "W") $(bits-spent - predecessor.bits-spent) bits, bytes: $(byte-oriented ? data-count : data-count*4)"
    return "$(%30s line) $old\n$(%30s   "") $new"

  move-cursor new-to-old/int new-position/int --fast/bool -> List:
    if new-bytes.size - new-position < 4: return Action.EMPTY
    if not old-bytes.valid old-position data-width: return Action.EMPTY

    // If we have a perfect match, don't bother trying to find other matches in
    // the old file.
    data-width.repeat:
      if old-bytes[old-position + it] != new-bytes[this.new-position + it]:
        return super new-to-old new-position --fast=fast
    return Action.EMPTY

  add-data new-position/int fast/bool -> List:
    if not old-bytes.valid old-position data-width:
      return super new-position fast
    diff := diff-table[0]
    wanted-diff := diff-to-int_ new-data - old-data
    if old-position + data-width <= old-bytes.size and wanted-diff == diff:
      // Match, so we keep building.  There are some lengths where we have
      // to move to a wider bit representation.
      new-bits-spent := predecessor.bits-spent
      emit-driver data-count + 1: | bits _ _ |
        new-bits-spent += bits
      // By passing this instance's previous action instead of this, we cut
      // out this from the chain.
      next := BuildingDiffZero_.private_ predecessor diff-table old-position + data-width new-position + data-width new-bits-spent data-count + 1
      next.years-past-its-prime = years-past-its-prime + data-width
      return [next]

    return super new-position fast

  comparable-hash-code -> int:
    hash := ordered-diff-hash_ data-count
    return hash

  compare other -> bool:
    if other is not BuildingDiffZero_: return false
    if other.data-count != data-count: return false
    return base-compare_ other

  rough-hash-code -> int:
    hash := unordered-diff-hash_ data-count
    hash += data-count-category
    return hash

  roughly-equals other -> bool:
    if other is not BuildingDiffZero_: return false
    if other.data-count-category != data-count-category: return false
    return unordered-compare_ other

  data-count-category -> int:
    if data-count < 4: return data-count
    if data-count < 10: return 4
    if data-count < 200: return 10
    return 200

class ComparableSet_ extends Set:
  hash-code_ key:
    return key.comparable-hash-code

  compare_ key key-or-probe:
    return key.compare key-or-probe

  add-or-improve key:
    existing-key := get key --if-absent=:
      add key
      null
    if existing-key and existing-key.worse-than key:
      add key  // Overwrites.

class RoughlyComparableSet_ extends Set:
  hash-code_ key:
    return key.rough-hash-code

  compare_ key key-or-probe:
    return key.roughly-equals key-or-probe

  add-or-improve key:
    existing-key := get key --if-absent=:
      add key
      null
    if existing-key and existing-key.roughly-worse-than key:
      add key  // Overwrites.

/// Old and new bytes match up, but their positions in the files are offset
/// relative to each other.
/// Determine, for each page of the new file, what offsets it is worth trying.
class NewOldOffsets:
  pages_/List

  // Determine new-old offsets per 128-byte page.
  static PAGE-BITS_ ::= 7

  // If a rolling hash occurs too many places in the old file then it's just
  // a common pattern like all-zeros.  These don't help us match up parts of
  // the old and new file, so we ignore them.
  static MAX-HASH-POPULARITY ::= 5

  // If a part of the new file matches up with too many places in the old
  // file then we don't keep track of all the places, because that just
  // slows us down when creating the diff.
  static MAX-OFFSETS ::= 32

  operator [] new-position/int -> Set:  // Of ints.
    return pages_[new-position >> PAGE-BITS_]

  constructor old-bytes/OldData new-bytes/ByteArray sections/Map section-size/int --fast/bool:
    pages_ = List (new-bytes.size >> PAGE-BITS_) + 2: Set

    byte-positions-per-word := fast ? 1 : 4

    adlers := List byte-positions-per-word: Adler32

    // The rolling Adler checksum requires that we 'unadd' data that is rolling
    // out of the window.  Special-case the initial area where we are near the
    // start and there is no data to unadd.
    for i:= 0; i < section-size; i += 4:
      byte-positions-per-word.repeat:
        adlers[it].add new-bytes i + 2 + it i + 4 + it

    for i := 0; i < new-bytes.size - 2 * section-size; i += 4:
      byte-positions-per-word.repeat: | j |
        adler := adlers[j]
        index := i + j
        rolling-hash := Section.hash-number (adler.get --destructive=false)
        if sections.contains rolling-hash:
          if sections[rolling-hash].size < MAX-HASH-POPULARITY:
            sections[rolling-hash].do: | section |
              mismatch := false
              if old-bytes.valid section.position section-size:
                for k := 0; k < section-size; k += 4:
                  if old-bytes[section.position + k + 2] != new-bytes[index + k + 2]: mismatch = true
                  if old-bytes[section.position + k + 3] != new-bytes[index + k + 3]: mismatch = true
              if not mismatch:
                new-to-old := section.position - index
                page := index >> PAGE-BITS_
                set := pages_[page]
                if set.size < MAX-OFFSETS: set.add new-to-old
        adler.unadd
          new-bytes
          index + 2
          index + 4
        adler.add
          new-bytes
          index + 2 + section-size
          index + 4 + section-size

diff-files old-bytes/OldData new-bytes/ByteArray pages/NewOldOffsets fast-mode/bool total-new-bytes=new-bytes.size --with-header=true --with-checksums=true [logger]:
  actions/Set := ComparableSet_
  state/Action := InitialState_ old-bytes new-bytes total-new-bytes --with-header=with-header
  if with-checksums:
    state = OldChecksumAction_ state old-bytes
  actions.add state

  last-time := Time.now
  last-size := 0

  new-bytes.size.repeat: | new-position |
    actions-at-this-point := actions.any:
      it.new-position == new-position
    // At some unaligned positions there are no actions to consider.
    assert: actions-at-this-point or not new-position.is-aligned 4
    if actions-at-this-point:
      new-actions := RoughlyComparableSet_
      best-bdiff-length := int.MAX
      not-in-this-round := []
      best-offset-printed := false
      at-unaligned-end-zone := new-position == (round-down new-bytes.size 4)
      fast := fast-mode and pages[new-position].size == 0 and not at-unaligned-end-zone
      actions.do: | action |
        limit := fast ? 16 : 64
        if actions.size > 1000 or new-actions.size > 1000: limit = fast ? 16 : 32
        if actions.size > 10000 or new-actions.size > 10000: limit = fast ? 8 : 16
        if action.new-position != new-position:
          not-in-this-round.add action
          best-bdiff-length = min best-bdiff-length action.bits-spent
        else:
          if at-unaligned-end-zone and not action.byte-oriented:
            action = MoveCursor_ action 0 true // Switch to byte oriented mode.
          possible-children := action.add-data new-position fast
          possible-children.do: | child |
            bits := child.bits-spent
            // Prefilter - no need to add actions that are already too poor.
            if bits - best-bdiff-length < limit:
              new-actions.add-or-improve child
              best-bdiff-length = min best-bdiff-length bits
          if (not fast-mode) or new-position & 0x7f == 0:
            pages[new-position].do: | new-to-old |
              jitters-done := false
              jitters := action.byte-oriented
                ? (new-position & 0xf == 0 ? [0, 1, -1, 2, -2, 3, -3] : [0, 1, -1])
                : [0]
              jitters.do: | jitter |
                if not jitters-done:
                  shifted-actions := action.move-cursor (new-to-old + jitter) new-position --fast=fast-mode
                  shifted-actions.do: | shifted-action |
                    jitters-done = true
                    shifted-children := shifted-action.add-data new-position fast
                    shifted-children.do: | shifted-child |
                      bits := shifted-child.bits-spent
                      if bits - best-bdiff-length < limit:
                        new-actions.add-or-improve shifted-child
                        best-bdiff-length = min best-bdiff-length bits
      actions = new-actions
      limit := 64
      if actions.size > 1000:
        limit = 32
      if actions.size > 10000:
        limit = 16
      if actions.size > 100:
        fuzzy-set := RoughlyComparableSet_
        actions.do:
          if it.bits-spent - best-bdiff-length < limit and not it.past-its-prime:
            fuzzy-set.add-or-improve it
          if it.bits-spent == best-bdiff-length:
            it.set-its-the-best
        actions = ComparableSet_
        actions.add-all fuzzy-set
      else:
        actions.filter --in-place:
          if it.bits-spent == best-bdiff-length:
            it.set-its-the-best
          result := it.bits-spent - best-bdiff-length <= limit
          if it.past-its-prime: result = false
          result
      actions.add-all not-in-this-round
      PROGRESS-EVERY ::= 10000
      if new-position % PROGRESS-EVERY == 0:
        end := Time.now
        size := best-bdiff-length
        duration := last-time.to end
        compressed-size := size - last-size
        compression-message := ""
        if new-position != 0:
          compression-message = "$(((compressed-size * 1000.0 / (8 * PROGRESS-EVERY)).to-int + 0.1)/10.0)%"
          point := compression-message.index-of "."
          compression-message = compression-message.copy 0 point + 2
          compression-message += "%"
          logger.call "Pos $(%7d new-position), $(%6d best-bdiff-length) bits, $(%6d (duration/PROGRESS-EVERY).in-us)us/byte $compression-message"
        last-time = end
        last-size = size
  end-state := null
  actions.do:
    if it.new-position == new-bytes.size:
      if not end-state or end-state.worse-than it:
        end-state = it
  return end-state

/**
A section of the old version of a diff-file pair.  By using a
  rolling checksum over the new version of the diff-file pair,
  matches can be found with sections like this.  This section
  is always aligned, but matches in the other file may be at
  any 4-byte aligned position.  The adler checksum is only
  computed over the two high-order bytes of each 4-byte word
  (little-endian is assumed).  The intention is to enable a
  fuzzy match when aligned addresses are offset in the two files.
*/
class Section:
  position/int
  size/int
  adler/ByteArray     // Adler32 of bytes 2 and 3 out of every 4-byte part.

  static first-eight-bytes hash/ByteArray -> string:
    return "$(%02x hash[0])$(%02x hash[1])$(%02x hash[2])$(%02x hash[3])"

  stringify:
    return "0x$(%06x position)-0x$(%06x position + size - 1): Rolling:$(first-eight-bytes adler)"

  constructor .position .size .adler:

  static hash-number hash/ByteArray -> int:
    return hash[0] + (hash[1] << 8) + (hash[2] << 16) + (hash[3] << 24)

  adler-number -> int:
    return hash-number adler

  adler-match a/Adler32:
    other := a.get --destructive=false
    if other.size != adler.size: return false
    other.size.repeat:
      if other[it] != adler[it]: return false
    return true

  static get-sections bytes/OldData section-size/int -> Map:
    sections := {:}
    for pos := 0; pos < bytes.size; pos += section-size:
      if bytes.valid pos section-size:
        half-adler := Adler32
        two := ByteArray 2
        for i := 0; i < section-size and pos + i < bytes.size; i += 4:
          two[0] = bytes[pos + i + 2]
          two[1] = bytes[pos + i + 3]
          half-adler.add two

        section := Section pos section-size half-adler.get
        number := section.adler-number
        list := (sections.get number --init=: [])
        if list.size < 16 or (pos / section-size) & 0x1f == 0:
          list.add section

    return sections

class Writer_:
  new-bytes/ByteArray
  fd := null
  number-of-bits := 0
  accumulator := 0

  constructor .new-bytes:

  write-diff file end-state/Action --with-footer=true -> int:
    bdiff-size := 0
    fd = file

    count := 1

    action/Action? := end-state
    while action.predecessor != null:
      count++
      action = action.predecessor
    all-actions := List count
    action = end-state
    while action:
      count--
      all-actions[count] = action
      action = action.predecessor

    last-action := PadAction_ end-state
    all-actions.add last-action

    if with-footer:
      end-action := EndAction_ last-action
      all-actions.add end-action

    one-byte-buffer := ByteArray 1
    all-actions.do: | action |
      next-byte-boundary := round-up number-of-bits 8
      (action.emit-bits next-byte-boundary - number-of-bits).do: | to-output/BitSequence_ |
        accumulator <<= to-output.number-of-bits
        accumulator |= to-output.bits
        number-of-bits += to-output.number-of-bits
        while number-of-bits >= 8:
          byte := (accumulator >> (number-of-bits - 8)) & 0xff
          one-byte-buffer[0] = byte
          fd.write one-byte-buffer
          bdiff-size++
          number-of-bits -= 8
          accumulator &= (1 << number-of-bits) - 1
        extra-bytes := to-output.byte-array-count
        position := to-output.byte-array-start
        while extra-bytes-- != 0:
          accumulator <<= 8
          accumulator |= to-output.byte-array[position++]
          one-byte-buffer[0] = (accumulator >> number-of-bits) & 0xff
          fd.write one-byte-buffer
          bdiff-size++
          accumulator &= 0xff  // Avoid Smi overflow.
    if number-of-bits != 0:
      one-byte-buffer[0] = (accumulator << (8 - number-of-bits)) & 0xff
      fd.write one-byte-buffer
      bdiff-size++

    return bdiff-size

int-vector-equals a/int b/int -> int:
  #primitive.core.int-vector-equals
