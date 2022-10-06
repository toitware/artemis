// Copyright (C) 2020 Toitware ApS. All rights reserved.

import binary show LITTLE_ENDIAN
import crypto.adler32 show *
import crypto.sha256 show *
import host.pipe
import writer

import ...shared.utils.patch_format

// Smaller numbers take longer, but get smaller diffs.
SECTION_SIZE_ ::= 16

/// Create a binary diff from $old_bytes to $new_bytes, and write it
/// to the open file, $fd.  Returns the size of the diff file in bytes.
diff old_bytes/OldData new_bytes/ByteArray fd total_new_bytes=new_bytes.size --fast/bool --with_header=true --with_footer=true --with_checksums=true -> int:
  pages := NewOldOffsets old_bytes new_bytes old_bytes.sections SECTION_SIZE_ --fast=fast

  bdiff_size := 0

  stderr := writer.Writer pipe.stderr

  end_state := diff_files old_bytes new_bytes pages fast total_new_bytes --with_header=with_header --with_checksums=with_checksums:
    stderr.write "$it\n"

  writer := Writer_ new_bytes
  bdiff_size += writer.write_diff fd end_state --with_footer=with_footer

  return bdiff_size

literal_block new_bytes/ByteArray fd --with_footer=false -> int:
  initial_state := InitialState_.no_old_bytes new_bytes
  literal_action := Literal_.literal_section initial_state new_bytes

  assert: literal_action.bits_spent & 7 == 0

  writer := Writer_ new_bytes

  bdiff_size := writer.write_diff fd literal_action --with_footer=with_footer

  return bdiff_size

new_checksum_block new_bytes/ByteArray fd checksum/ByteArray --with_header=true -> int:
  initial_state := InitialState_.no_old_bytes new_bytes --with_header
  checksum_action := NewChecksumAction_ initial_state --checksum=checksum

  assert: checksum_action.bits_spent & 7 == 0

  writer := Writer_ new_bytes

  bdiff_size := writer.write_diff fd checksum_action --with_footer=false

  return bdiff_size

class BitSequence_:
  bits/int
  number_of_bits/int
  byte_array/ByteArray? := null
  byte_array_start/int := 0
  byte_array_count/int := 0

  constructor .number_of_bits .bits:

  constructor .number_of_bits .bits .byte_array .byte_array_start=0 .byte_array_count=byte_array.size:

  static metadata_bits_ data -> ByteArray:
    // Prepend 16 bit big-endian size field, in bits.
    return ByteArray data.size + 2:
      if it < 2:
        size := data.size * 8
        continue.ByteArray (size >> (8 - (it * 8))) & 0xff
      continue.ByteArray data[it - 2]

  static empty_byte_array_ := ByteArray 0

  constructor.metadata code/int --ignorable/bool data=empty_byte_array_:
    number_of_bits = 16
    assert: 0 <= code <= 0x7f
    bits = (ignorable ? IGNORABLE_METADATA : NON_IGNORABLE_METADATA) + code
    byte_array = metadata_bits_ data
    byte_array_start = 0
    byte_array_count = byte_array.size

/// Immutable diff table structure.  Always returns a new
/// one rather than mutating it.  This is used for creating
/// diffs, but a mutable version is more efficient for
/// patching.
class DiffTable_:
  diffs_/List := List DIFF_TABLE_SIZE: 0

  constructor:

  constructor.private_ .diffs_:

  operator [] index -> int:
    return diffs_[index]

  /// Puts a new value in the middle and shifts the later items down
  /// by one.
  insert value/int -> DiffTable_:
    pos := DIFF_TABLE_INSERTION
    new_diffs := List DIFF_TABLE_SIZE:
      it <= pos ? diffs_[it] : diffs_[it - 1]
    new_diffs[pos] = value
    return DiffTable_.private_ new_diffs

  make_entry_zero_zero -> DiffTable_:
    if diffs_[0] == 0: return this
    zero_found := false
    new_diffs := List DIFF_TABLE_SIZE:
      result := zero_found ? diffs_[it] : (it == 0 ? 0 : diffs_[it - 1])
      if diffs_[it] == 0:
        zero_found = true
      result
    return DiffTable_.private_ new_diffs

  /// Find the position of a number in the table or return null if
  /// it's not there.
  index_of value/int? -> int?:
    if not value: return null
    diffs_.size.repeat: if diffs_[it] == value: return it
    return null

  /// When an item in the table is used, it moves half as close to
  /// the start, and other items are moved down.
  promote index/int -> DiffTable_:
    if index == 0: return this
    new_position := index / 2
    new_diffs := List DIFF_TABLE_SIZE:
      (it < new_position or it > index) ? diffs_[it] : it == new_position ? diffs_[index] : diffs_[it - 1]
    return DiffTable_.private_ new_diffs

class OldData:
  bytes/ByteArray
  ignore_from/int
  ignore_to/int
  sections/Map? := null

  constructor .bytes .ignore_from=0 .ignore_to=0:
    if bytes.size != 0:
      sections = Section.get_sections this SECTION_SIZE_

  size -> int:
    return bytes.size

  valid index/int length=1 -> bool:
    assert: length > 0
    if index < 0: return false
    if index + length > size: return false
    if ignore_to <= index: return true
    if index + length <= ignore_from: return true
    return false

  operator [] index/int:
    if ignore_from <= index < ignore_to: throw "Out of bounds"
    return bytes[index]

  read_int32 index/int:
    if ignore_from - 4 < index < ignore_to: throw "Out of bounds"
    return LITTLE_ENDIAN.read_int bytes 4 index

abstract class Action:
  old_bytes/OldData     // Same for all actions.
  new_bytes/ByteArray   // Same for all actions.
  predecessor/Action?   // The chain back in time of immutable actions.
  diff_table/DiffTable_  // The following values represent the situation after this action.
  old_position/int
  new_position/int
  bits_spent/int
  byte_oriented/bool
  years_past_its_prime/int := 0

  constructor.private_ .predecessor .diff_table .old_position .new_position .bits_spent:
    byte_oriented = predecessor.byte_oriented
    old_bytes = predecessor.old_bytes
    new_bytes = predecessor.new_bytes
    years_past_its_prime = predecessor.years_past_its_prime + predecessor.data_width_

  constructor.private_ .predecessor .diff_table .old_position .new_position .bits_spent .byte_oriented:
    old_bytes = predecessor.old_bytes
    new_bytes = predecessor.new_bytes
    years_past_its_prime = predecessor.years_past_its_prime + predecessor.data_width_

  constructor.private_ .predecessor .diff_table .old_position .new_position .bits_spent .byte_oriented .old_bytes .new_bytes:

  set_its_the_best -> none:
    years_past_its_prime = 0

  past_its_prime -> bool:
    return years_past_its_prime > 500

  // *** Methods for the ComparableSet_ ***
  abstract comparable_hash_code -> int
  abstract compare other -> bool
  worse_than other -> bool:
    return other.bits_spent < bits_spent

  // Compare that fits with ordered_diff_hash.
  base_compare_ other -> bool:
    if other.old_position != old_position: return false
    if other.byte_oriented != byte_oriented: return false
    (DIFF_TABLE_INSERTION + 1).repeat:
      if diff_table[it] != other.diff_table[it]: return false
    return true

  // Hash that fits with base_compare_
  ordered_diff_hash_ seed -> int:
    hash := seed
    if byte_oriented: hash += 57
    (DIFF_TABLE_INSERTION + 1).repeat:
      hash *= 11
      hash += diff_table[it]
      hash &= 0x1fff_ffff
    hash += old_position * 13
    hash &= 0x1fff_ffff
    return hash

  // *** Methods for the RoughlyComparableSet_ ***
  abstract rough_hash_code -> int
  abstract roughly_equals other -> bool
  roughly_worse_than other -> bool:
    return other.bits_spent < bits_spent

  // Compare that fits with unordered_diff_hash.
  unordered_compare_ other -> bool:
    if other.byte_oriented != byte_oriented: return false
    if other.old_position != old_position: return false
    if byte_oriented:
      assert: diff_table[0] == 0
      if other.diff_table[1] != diff_table[1]: return false
    else:
      if other.diff_table[0] != diff_table[0]: return false
    return true

  // Hash that fits with unordered_compare_.  Seed is a per-class constant.
  unordered_diff_hash_ seed -> int:
    sum := seed
    product := seed | 1
    eor := 0
    diff := diff_table[byte_oriented ? 1 : 0]
    sum += diff
    if diff == 0:
      product *= 941
    else:
      product *= diff
    product &= 0xfffff
    eor ^= diff
    if byte_oriented: sum += 57
    return (941 + sum + product + eor) & 0x1fff_ffff

  diff_to_int_ value/int?:
    if byte_oriented:
      integer := value & 0xff
      if integer >= 0x80: integer -= 0x100 // Treat as signed byte.
      return integer
    // Treat as signed 32 bit value.
    value &= 0xffff_ffff
    if value >= 0x8000_0000: value -= 0x1_0000_0000
    if 0 - 0x8000 <= value <= 0x7fff: return value
    return null

  data_width_ -> int:
    return byte_oriented ? 1 : 4

  old_data -> int:
    if byte_oriented:
      return old_bytes[old_position]
    return old_bytes.read_int32 old_position

  new_data -> int:
    if byte_oriented:
      return new_bytes[new_position]
    return LITTLE_ENDIAN.read_int new_bytes 4 new_position

  add_data new_position/int fast/bool -> List:
    wanted_diff := null

    if not byte_oriented:
      assert: old_position & 3 == 0
      assert: new_position & 3 == 0

    if old_bytes.valid old_position data_width_:
      wanted_diff = diff_to_int_ new_data - old_data
      // If a diff table entry fits, it's the best move.
      index := diff_table.index_of wanted_diff
      if index:
        return [create_diff_ new_data index]
    // No existing diff table entry fits.  We can either overwrite a
    // byte/word or add a new diff table entry.
    result := []
    if wanted_diff and not fast:
      worth := not byte_oriented
      if byte_oriented and old_bytes.valid old_position 17:
        16.repeat:
          ahead := it + 1
          if old_position + ahead < old_bytes.size and new_position + ahead < new_bytes.size:
            if (old_bytes[old_position + ahead] + wanted_diff) & 0xff == new_bytes[new_position + ahead]:
              worth = true
      if worth:
        result.add
          NewDiffEntry_ this new_data
    result.add
      Literal_ this new_data new_position
    return result

  move_cursor new_to_old/int new_position/int --fast=null -> List:
    current_new_to_old := old_position - new_position
    diff := new_to_old - current_new_to_old
    possible_old_position := new_position + new_to_old
    if not old_bytes.valid possible_old_position 8: return []
    if new_position >= new_bytes.size - 8: return []
    match_count := 0
    8.repeat:
      if old_bytes[possible_old_position + it] == new_bytes[new_position + it]:
        match_count++
    if match_count < 5: return []
    result := []
    if not byte_oriented:
      // Currently word oriented.
      if new_to_old & 3 == 0:
        assert: current_new_to_old & 3 == 0
        if diff != 0:
          result.add
            MoveCursor_ this diff false  // Word oriented.
      if not fast:
        result.add
          MoveCursor_ this diff true  // Byte oriented.
    else:
      // Currently byte oriented.
      if new_position & 3 == 0 and new_to_old & 3 == 0:
        result.add
          MoveCursor_ this diff false // Word oriented.
      if diff != 0:
        result.add
          MoveCursor_ this diff true // Byte oriented.
    return result

  create_diff_ data/int index/int:
    if index == 0:
      return BuildingDiffZero_ this data
    // A non-zero diff can't be promoted to the zero position in
    // byte mode.
    new_diff_table := (index == 1 and byte_oriented) ? diff_table : (diff_table.promote index)
    return DiffTableAction_ this new_diff_table data index

  short_string -> string:
    return stringify

  old_representation_ bytes/int -> string:
    old := ""
    pos := old_position - bytes
    (min 8 bytes).repeat:
      old += "$(%02x old_bytes[pos + it]) "
    if bytes > 8:
      old += "..."
    return "$(%-30s old) $(%8d pos)"

  new_representation_ bytes/int -> string:
    new := ""
    pos := new_position - bytes
    (min 8 bytes).repeat:
      new += "$(%02x new_bytes[pos + it]) "
    if bytes > 8:
      new += "..."
    return "$(%-30s new) $(%8d pos)"

/// Returns a non-negative number as a series of bytes in big-endian order.
metadata_number_ x:
  assert: x >= 0
  little_endian := []
  while x != 0:
    little_endian.add x & 0xff
    x >>= 8
  big_endian := []
  little_endian.do --reversed: big_endian.add it
  return big_endian

class InitialState_ extends Action:
  with_header_ ::= ?
  // Total size of the result.  This may be after some binary patches have been
  // concatenated, so it may not reflect the size of the current block being
  // diffed.
  total_new_bytes_/int

  constructor old_bytes/OldData new_bytes/ByteArray .total_new_bytes_=new_bytes.size --with_header=true:
    with_header_ = with_header
    super.private_ null DiffTable_ 0 0 0 false old_bytes new_bytes

  constructor.no_old_bytes bytes/ByteArray --with_header=false:
    with_header_ = with_header
    total_new_bytes_ = 0
    dummy_old_data := OldData (ByteArray 0) 0 0
    super.private_ null DiffTable_ 0 0 0 false dummy_old_data bytes

  emit_bits optional_pad/int -> List:
    result := []
    if with_header_:
      magic := [0x70, 0x17, 0xd1, 0xff]  // 0x7017d1ff.
      result.add
        BitSequence_.metadata 'M' --ignorable=false magic
      if total_new_bytes_ != 0:
        result.add
          BitSequence_.metadata 'n' --ignorable=true (metadata_number_ total_new_bytes_)
    else:
      // Add state reset action instead of header so that sections can be
      // concatenated.
      result.add
        BitSequence_.metadata 'R' --ignorable=false
    return result

  stringify -> string:
    return "Initial State"

  short_string -> string:
    return "Initial    $(bits_spent) bits, offset: $(old_position - new_position)"

  comparable_hash_code -> int:
    return 123

  compare other -> bool:
    return false

  rough_hash_code -> int:
    return 123

  roughly_equals other -> bool:
    return false

class SpecialAction_ extends Action:
  hash_code_ := 0
  constructor predecessor/Action bits_spent/int=predecessor.bits_spent:
    super.private_ predecessor predecessor.diff_table predecessor.old_position predecessor.new_position bits_spent
    hash_code_ = random 0 1_000_000_000

  comparable_hash_code -> int:
    return hash_code_

  compare other -> bool:
    return identical this other

  rough_hash_code -> int:
    return hash_code_

  roughly_equals other -> bool:
    return identical this other

class OldChecksumAction_ extends SpecialAction_:
  old_data_/OldData ::= ?

  constructor predecessor/Action .old_data_:
    super predecessor

  emit_bits optional_pad/int -> List:
    result := []
    if old_data_.ignore_from > 0:
      old_sha := sha256 old_data_.bytes 0 old_data_.ignore_from
      payload := create_old_sha_payload_ old_sha 0 old_data_.ignore_from
      result.add
        BitSequence_.metadata 'S' --ignorable=true payload
    if old_data_.ignore_to < old_data_.size:
      old_sha := sha256 old_data_.bytes old_data_.ignore_to old_data_.size
      payload := create_old_sha_payload_ old_sha old_data_.ignore_to old_data_.size - old_data_.ignore_to
      result.add
        BitSequence_.metadata 'S' --ignorable=true payload
    return result

  create_old_sha_payload_ sha/ByteArray from/int size/int -> ByteArray:
    old_payload := ByteArray 6 + sha.size: | index |
      if index < 3: continue.ByteArray (from >> (16 - 8 * index)) & 0xff
      index -= 3
      if index < 3: continue.ByteArray (size >> (16 - 8 * index)) & 0xff
      index -= 3
      continue.ByteArray sha[index]
    return old_payload

  stringify -> string:
    return "Old checksum"

class NewChecksumAction_ extends SpecialAction_:
  checksum := null

  constructor predecessor/Action --.checksum=null:
    super predecessor

  emit_bits optional_pad/int -> List:
    assert: checksum.size == 32
    return [BitSequence_.metadata 's' --ignorable=true checksum]

  stringify -> string:
    return "New checksum"

class EndAction_ extends SpecialAction_:
  constructor predecessor/Action:
    super predecessor

  emit_bits optional_pad/int -> List:
    return [BitSequence_.metadata 'E' --ignorable=false]

  short_string -> string:
    return "End        $(bits_spent - predecessor.bits_spent) bits, offset: $(old_position - new_position)"

/// Used to pad output up to a whole number of bytes.  If we were already
/// aligned it takes 0 bits, otherwise 17-23 bits.
class PadAction_ extends SpecialAction_:
  constructor predecessor/Action:
    super predecessor

  emit_bits pad_bits/int -> List:
    result := []
    emit_driver pad_bits: | bits bit_pattern |
      result.add
        BitSequence_ bits bit_pattern
    return result

  static emit_driver pad_bits [block] -> none:
    if pad_bits == 0: return
    assert: 0 < pad_bits <= 7
    block.call
      16 + pad_bits
      // We use the code that moves the old-data cursor by 0 bytes.
      0b1111_1110_1000_0000 << pad_bits

  short_string -> string:
    return "Pad        , offset: $(old_position - new_position)"

class MoveCursor_ extends Action:
  step/int

  constructor predecessor/Action .step/int byte_oriented/bool:
    extra_bits := 8
    if step.abs != 1: extra_bits = 16
    if not -128 <= step <= 127: extra_bits = 32
    if predecessor.byte_oriented != byte_oriented: extra_bits = 32
    if step == 0 and predecessor.byte_oriented != byte_oriented: extra_bits = 8
    assert: predecessor.old_position + step >= 0
    new_diff_table := predecessor.diff_table
    if (not predecessor.byte_oriented) and byte_oriented:
      // In byte oriented mode the first entry in the diff table is always
      // zero, but this is not the case in word oriented mode.
      new_diff_table = new_diff_table.make_entry_zero_zero
    super.private_
      predecessor
      new_diff_table
      predecessor.old_position + step
      predecessor.new_position
      predecessor.bits_spent + extra_bits
      byte_oriented

  emit_bits optional_pad/int -> List:
    if step == 0 and predecessor.byte_oriented != byte_oriented:
      return [BitSequence_ 8 0b1111_1111]
    in_byte_range := 0 - 0x80 <= step <= 0x7f
    if predecessor.byte_oriented != byte_oriented or not in_byte_range:
      location := ByteArray 3: (old_position >> (8 * (2 - it))) & 0xff
      flag := byte_oriented ? 1 : 0
      return [BitSequence_ 8 0b1110_1110 + flag location 0 3]
    if step.abs == 1:
      if step == 1:
        return [BitSequence_ 8 0b1111_1101]
      else:
        return [BitSequence_ 8 0b1111_1100]
    assert: in_byte_range
    return [BitSequence_ 16 0b1111_1110_0000_0000 + ((step + 0x80) & 0xff)]

  comparable_hash_code -> int:
    hash := ordered_diff_hash_ 103
    // Don't use the step for the hash - it's where we land, not how
    // we got there.
    return hash

  compare other/Action -> bool:
    if other is not MoveCursor_: return false
    return base_compare_ other

  rough_hash_code -> int:
    hash := unordered_diff_hash_ 103
    return hash

  roughly_equals other -> bool:
    if other is not MoveCursor_: return false
    return unordered_compare_ other

  stringify -> string:
    entries := ""
    DIFF_TABLE_SIZE.repeat:
      entries += "$diff_table[it], "
    return "$(byte_oriented ? "B" : "W") Move cursor, old_position $old_position, $bits_spent bits spent, $entries"

  short_string -> string:
    return "Offset   $(byte_oriented ? "B" : "W") $(bits_spent - predecessor.bits_spent) bits, offset: $(old_position - new_position)"

class NewDiffEntry_ extends Action:
  diff/int

  constructor predecessor/Action data/int:
    wanted_diff := predecessor.diff_to_int_ data - predecessor.old_data
    assert: wanted_diff
    diff = wanted_diff
    extra_bits := (one_byte_ wanted_diff predecessor.byte_oriented) ? 14 : 22
    super.private_
      predecessor
      predecessor.diff_table.insert wanted_diff
      predecessor.old_position + predecessor.data_width_
      predecessor.new_position + predecessor.data_width_
      predecessor.bits_spent + extra_bits

  emit_bits optional_pad/int -> List:
    byte := one_byte_ diff byte_oriented
    if byte:
      return [BitSequence_ 14 0b1111_00_0000_0000 + byte]
    assert: 0 - 0x8000 <= diff <= 0x7fff
    return [BitSequence_ 22 0b1111_01_0000_0000_0000_0000 + diff + 0x8000]

  /// If the difference can be represented as a signed 8 bit value, then
  /// returns that difference, biased by 0x80.  Otherwise returns null.
  static one_byte_ diff/int byte_oriented/bool -> int?:
    if byte_oriented:
      masked := diff & 0xff
      signed := masked >= 0x80  ? masked - 0x100 : masked
      return signed + 0x80
    if 0 - 0x80 <= diff <= 0x7f:
      return diff + 0x80
    return null

  stringify -> string:
    entries := ""
    DIFF_TABLE_SIZE.repeat:
      entries += "$diff_table[it], "
    return "$(byte_oriented ? "B" : "W") New diff, $bits_spent bits spent, $entries"// $name from $predecessor.name"

  short_string -> string:
    old := old_representation_ data_width_
    new := new_representation_ data_width_
    line := "New diff $(byte_oriented ? "B" : "W") $(bits_spent - predecessor.bits_spent) bits"
    return "$(%30s line) $old\n$(%30s   "") $new"

  comparable_hash_code -> int:
    hash := ordered_diff_hash_ 41
    return hash

  compare other -> bool:
    if other is not NewDiffEntry_: return false
    return base_compare_ other

  rough_hash_code -> int:
    hash := unordered_diff_hash_ 41
    return hash

  roughly_equals other -> bool:
    if other is not NewDiffEntry_: return false
    return unordered_compare_ other

class DiffTableAction_ extends Action:
  index/int

  emit_bits optional_pad/int -> List:
    if index == 1: return [BitSequence_ 3 0b100]
    if index <= 3: return [BitSequence_ 4 0b1010 + index - 2]
    if index <= 7: return [BitSequence_ 5 0b11000 + index - 4]
    return [BitSequence_ 8 0b1110_0000 + index - 8]

  constructor predecessor/Action new_diff_table/DiffTable_ data/int .index:
    assert: index != null
    assert: index != 0
    extra_bits := 0
    if index == 1: extra_bits = 3
    else if index <= 3: extra_bits = 4
    else if index <= 7: extra_bits = 5
    else: extra_bits = 8
    super.private_
      predecessor
      new_diff_table
      predecessor.old_position + predecessor.data_width_
      predecessor.new_position + predecessor.data_width_
      predecessor.bits_spent + extra_bits

  stringify -> string:
    entries := ""
    DIFF_TABLE_SIZE.repeat:
      entries += "$diff_table[it], "
    return "$(byte_oriented ? "B" : "W") Diff at $index by $diff_table[index], $bits_spent bits spent, $entries"// $name from $predecessor.name"

  short_string -> string:
    old := old_representation_ data_width_
    new := new_representation_ data_width_
    line := "Diff   $(byte_oriented ? "B" : "W") $(bits_spent - predecessor.bits_spent) bits, index: $index"
    return "$(%30s line) $old\n$(%30s   "") $new"

  comparable_hash_code -> int:
    hash := ordered_diff_hash_ index
    return hash

  compare other -> bool:
    if other is not DiffTableAction_: return false
    if other.index != index: return false
    return base_compare_ other

  rough_hash_code -> int:
    hash := unordered_diff_hash_ 71
    return hash

  roughly_equals other -> bool:
    if other is not DiffTableAction_: return false
    return unordered_compare_ other

/// We are adding literal data.
class Literal_ extends Action:
  byte_count/int
  new_position_/int

  constructor predecessor/Action data/int .new_position_/int:
    byte_count = predecessor.data_width_
    super.private_
      predecessor
      predecessor.diff_table
      predecessor.old_position + predecessor.data_width_  // Overwrite, so we still step forwards.
      predecessor.new_position + predecessor.data_width_  // Overwrite, so we still step forwards.
      predecessor.bits_spent + 8 + 8 * predecessor.data_width_

  constructor.literal_section predecessor/Action bytes/ByteArray:
    new_position_ = 0
    byte_count = bytes.size
    assert: bytes.size & 3 == 0
    new_bits_spent := predecessor.bits_spent
    emit_driver byte_count 4: | bits _ _ length |
      new_bits_spent += bits + length * 8
    super.private_
      predecessor
      predecessor.diff_table
      predecessor.old_position + byte_count
      predecessor.new_position + byte_count
      new_bits_spent

  constructor.private_ predecessor/Literal_:
    byte_count = predecessor.byte_count + predecessor.data_width_
    new_bits_spent := predecessor.predecessor.bits_spent
    emit_driver byte_count predecessor.data_width_: | bits _ _ length |
      new_bits_spent += bits + length * 8
    new_position_ = predecessor.new_position_
    super.private_
      predecessor.predecessor  // Chop previous action out of chain.
      predecessor.diff_table
      predecessor.old_position + predecessor.data_width_  // Overwrite, so we still step forwards.
      predecessor.new_position + predecessor.data_width_  // Overwrite, so we still step forwards.
      new_bits_spent

  emit_bits optional_pad/int -> List:
    result := []
    if byte_count >= 64:
      // If we have a large-ish number of literal bytes it is worth spending
      // 17-23 bits to byte align first - this ensures that we can use
      // memcpy-like operations when patching.
      PadAction_.emit_driver optional_pad: | bits bit_pattern |
        result.add
          BitSequence_ bits bit_pattern

    emit_driver byte_count data_width_: | bits bit_pattern from length |
      result.add
        BitSequence_ bits bit_pattern new_bytes new_position_+from length
    return result

  static emit_driver byte_count/int data_width/int [block]-> none:
    datum_count := byte_count / data_width
    offset := 0
    while datum_count > 6:
      chunk := min 262 datum_count
      block.call 16 0b1111_1011_0000_0000 + chunk - 7 offset chunk * data_width
      offset += chunk * data_width
      datum_count -= chunk
    while datum_count > 0:
      chunk := min 3 datum_count
      block.call 8 0b11111000 + chunk - 1 offset chunk * data_width
      offset += chunk * data_width
      datum_count -= chunk

  add_data new_position/int fast/bool -> List:
    assert: new_position == new_position_ + byte_count
    result := super new_position fast
    extended := Literal_.private_ this
    extended.years_past_its_prime = years_past_its_prime + data_width_
    if result.size != 0 and result[result.size - 1] is Literal_:
      result[result.size - 1] = extended
    else:
      result.add extended
    return result

  stringify -> string:
    entries := ""
    DIFF_TABLE_SIZE.repeat:
      entries += "$diff_table[it], "
    return "$(byte_oriented ? "B" : "W") Literal_ length $byte_count, $bits_spent bits spent, $entries"// $name from $predecessor.name"

  short_string -> string:
    old := old_representation_ byte_count
    new := new_representation_ byte_count
    line := "Literl $(byte_oriented ? "B" : "W") $(bits_spent - predecessor.bits_spent) bits, bytes: $byte_count"
    return "$(%30s line) $old\n$(%30s   "") $new"

  byte_count_category_ -> int:
    if byte_count < 10: return byte_count
    if byte_count < 200: return 10
    return 200

  comparable_hash_code -> int:
    hash := ordered_diff_hash_ 521
    hash += byte_count_category_ * 53
    hash &= 0x1fff_ffff
    return hash

  compare other -> bool:
    if other is not Literal_: return false
    if other.byte_count_category_ != byte_count_category_: return false
    return base_compare_ other

  rough_hash_code -> int:
    hash := unordered_diff_hash_ 521
    hash += byte_count_category_ * 53
    hash &= 0x1fff_ffff
    return hash

  roughly_equals other -> bool:
    if other is not Literal_: return false
    if other.byte_count_category_ != byte_count_category_: return false
    return unordered_compare_ other

/// We are building up a sequence of matches of entry 0
/// in the diff table.
class BuildingDiffZero_ extends Action:
  data_count/int

  constructor predecessor/Action data/int:
    data_count = 1
    super.private_
      predecessor
      predecessor.diff_table
      predecessor.old_position + predecessor.data_width_
      predecessor.new_position + predecessor.data_width_
      predecessor.bits_spent + 2

  constructor.private_ predecessor diff_table old_position new_position bits_spent .data_count:
    super.private_ predecessor diff_table old_position new_position bits_spent

  emit_bits optional_pad/int -> List:
    list := []
    emit_driver data_count: | bit_count pattern argument |
      list.add
        BitSequence_ bit_count pattern + argument
    return list

  //  2, 0b00, 0, 1,        // 00          Diff index 0 1.
  //  2, 0b01, 2, 3,        // 01xx        Diff index 0 3-5.
  //  4, 0b0111, 4, 11,     // 0111xxxx    Diff index 0 11-23.
  //  8, 0b01111101, 8, 47, // 01111101    Diff index 0 47-302.
  //  8, 0b01111110, 16, 255, // 01111110  Diff index 0 255-65790.
  static emit_driver count/int [block]-> none:
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
    DIFF_TABLE_SIZE.repeat:
      entries += "$diff_table[it], "
    return "$(byte_oriented ? "B" : "W") Zero diff, $data_count bytes, $bits_spent bits spent, age $years_past_its_prime, $entries"// $name from $predecessor.name"

  short_string -> string:
    old := old_representation_ data_count * data_width_
    new := new_representation_ data_count * data_width_
    line := "0 diff $(byte_oriented ? "B" : "W") $(bits_spent - predecessor.bits_spent) bits, bytes: $(byte_oriented ? data_count : data_count*4)"
    return "$(%30s line) $old\n$(%30s   "") $new"

  move_cursor new_to_old/int new_position/int --fast=null -> List:
    if new_bytes.size - new_position < 4: return []
    if not old_bytes.valid old_position data_width_: return []

    // If we have a perfect match, don't bother trying to find other matches in
    // the old file.
    data_width_.repeat:
      if old_bytes[old_position + it] != new_bytes[this.new_position + it]:
        return super new_to_old new_position --fast=fast
    return []

  add_data new_position/int fast/bool -> List:
    if not old_bytes.valid old_position data_width_:
      return super new_position fast
    diff := diff_table[0]
    wanted_diff := diff_to_int_ new_data - old_data
    if old_position + data_width_ <= old_bytes.size and wanted_diff == diff:
      // Match, so we keep building.  There are some lengths where we have
      // to move to a wider bit representation.
      new_bits_spent := predecessor.bits_spent
      emit_driver data_count + 1: | bits _ _ |
        new_bits_spent += bits
      // By passing this instance's previous action instead of this, we cut
      // out this from the chain.
      next := BuildingDiffZero_.private_ predecessor diff_table old_position + data_width_ new_position + data_width_ new_bits_spent data_count + 1
      next.years_past_its_prime = years_past_its_prime + data_width_
      return [next]

    return super new_position fast

  comparable_hash_code -> int:
    hash := ordered_diff_hash_ data_count
    return hash

  compare other -> bool:
    if other is not BuildingDiffZero_: return false
    if other.data_count != data_count: return false
    return base_compare_ other

  rough_hash_code -> int:
    hash := unordered_diff_hash_ data_count
    return hash

  roughly_equals other -> bool:
    if other is not BuildingDiffZero_: return false
    if other.data_count != data_count: return false
    return unordered_compare_ other

class ComparableSet_ extends Set:
  hash_code_ key:
    return key.comparable_hash_code

  compare_ key key_or_probe:
    return key.compare key_or_probe

  add_or_improve key:
    existing_key := get key --if_absent=:
      add key
      null
    if existing_key and existing_key.worse_than key:
      add key  // Overwrites.

class RoughlyComparableSet_ extends Set:
  hash_code_ key:
    return key.rough_hash_code

  compare_ key key_or_probe:
    return key.roughly_equals key_or_probe

  add_or_improve key:
    existing_key := get key --if_absent=:
      add key
      null
    if existing_key and existing_key.roughly_worse_than key:
      add key  // Overwrites.

/// Old and new bytes match up, but their positions in the files are offset
/// relative to each other.
/// Determine, for each page of the new file, what offsets it is worth trying.
class NewOldOffsets:
  pages_/List

  // Determine new-old offsets per 128-byte page.
  static PAGE_BITS_ ::= 7

  // If a rolling hash occurs too many places in the old file then it's just
  // a common pattern like all-zeros.  These don't help us match up parts of
  // the old and new file, so we ignore them.
  static MAX_HASH_POPULARITY ::= 5

  // If a part of the new file matches up with too many places in the old
  // file then we don't keep track of all the places, because that just
  // slows us down when creating the diff.
  static MAX_OFFSETS ::= 32

  operator [] new_position/int -> Set:  // Of ints.
    return pages_[new_position >> PAGE_BITS_]

  constructor old_bytes/OldData new_bytes/ByteArray sections/Map section_size/int --fast/bool:
    pages_ = List (new_bytes.size >> PAGE_BITS_) + 2: Set

    byte_positions_per_word := fast ? 1 : 4

    adlers := List byte_positions_per_word: Adler32

    // The rolling Adler checksum requires that we 'unadd' data that is rolling
    // out of the window.  Special-case the initial area where we are near the
    // start and there is no data to unadd.
    for i:= 0; i < section_size; i += 4:
      byte_positions_per_word.repeat:
        adlers[it].add new_bytes i + 2 + it i + 4 + it

    for i := 0; i < new_bytes.size - 2 * section_size; i += 4:
      byte_positions_per_word.repeat: | j |
        adler := adlers[j]
        index := i + j
        rolling_hash := Section.hash_number (adler.get --destructive=false)
        if sections.contains rolling_hash:
          if sections[rolling_hash].size < MAX_HASH_POPULARITY:
            sections[rolling_hash].do: | section |
              mismatch := false
              if old_bytes.valid section.position section_size:
                for k := 0; k < section_size; k += 4:
                  if old_bytes[section.position + k + 2] != new_bytes[index + k + 2]: mismatch = true
                  if old_bytes[section.position + k + 3] != new_bytes[index + k + 3]: mismatch = true
              if not mismatch:
                new_to_old := section.position - index
                page := index >> PAGE_BITS_
                set := pages_[page]
                if set.size < MAX_OFFSETS: set.add new_to_old
                // TODO: Should we spread the offset to adjacent pages?
        adler.unadd
          new_bytes
          index + 2
          index + 4
        adler.add
          new_bytes
          index + 2 + section_size
          index + 4 + section_size

diff_files old_bytes/OldData new_bytes/ByteArray pages/NewOldOffsets fast_mode/bool total_new_bytes=new_bytes.size --with_header=true --with_checksums=true [logger]:
  actions := ComparableSet_
  state/Action := InitialState_ old_bytes new_bytes total_new_bytes --with_header=with_header
  if with_checksums:
    state = OldChecksumAction_ state old_bytes
  actions.add state

  last_time := Time.now
  last_size := 0

  new_bytes.size.repeat: | new_position |
    actions_at_this_point := actions.any:
      it.new_position == new_position
    if actions_at_this_point:
      new_actions := ComparableSet_
      best_bdiff_length := int.MAX
      not_in_this_round := []
      best_offset_printed := false
      fast := fast_mode and pages[new_position].size == 0
      actions.do: | action |
        limit := fast ? 16 : 64
        if actions.size > 1000 or new_actions.size > 1000: limit = fast ? 16 : 32
        if actions.size > 10000 or new_actions.size > 10000: limit = fast ? 8 : 16
        if action.new_position != new_position:
          not_in_this_round.add action
          best_bdiff_length = min best_bdiff_length action.bits_spent
        else:
          possible_children := action.add_data new_position fast
          possible_children.do: | child |
            bits := child.bits_spent
            // Prefilter - no need to add actions that are already too poor.
            if bits - best_bdiff_length < limit:
              new_actions.add_or_improve child
              best_bdiff_length = min best_bdiff_length bits
          if (not fast_mode) or new_position & 0x7f == 0:
            pages[new_position].do: | new_to_old |
              jitters_done := false
              jitters := action.byte_oriented
                ? (new_position & 0xf == 0 ? [0, 1, -1, 2, -2, 3, -3] : [0, 1, -1])
                : [0]
              jitters.do: | jitter |
                if not jitters_done:
                  shifted_actions := action.move_cursor new_to_old+jitter new_position --fast=fast_mode
                  shifted_actions.do: | shifted_action |
                    jitters_done = true
                    shifted_children := shifted_action.add_data new_position fast
                    shifted_children.do: | shifted_child |
                      bits := shifted_child.bits_spent
                      if bits - best_bdiff_length < limit:
                        new_actions.add_or_improve shifted_child
                        best_bdiff_length = min best_bdiff_length bits
      actions = new_actions
      limit := 64
      if actions.size > 1000:
        limit = 32
      if actions.size > 10000:
        limit = 16
      if actions.size > 100:
        fuzzy_set := RoughlyComparableSet_
        actions.do:
          if it.bits_spent - best_bdiff_length < limit and not it.past_its_prime:
            fuzzy_set.add_or_improve it
          if it.bits_spent == best_bdiff_length:
            it.set_its_the_best
        actions = ComparableSet_
        actions.add_all fuzzy_set
      else:
        actions.filter --in_place:
          if it.bits_spent == best_bdiff_length:
            it.set_its_the_best
          result := it.bits_spent - best_bdiff_length <= limit
          if it.past_its_prime: result = false
          result
      actions.add_all not_in_this_round
      PROGRESS_EVERY ::= 10000
      if new_position % PROGRESS_EVERY == 0:
        end := Time.now
        size := best_bdiff_length
        duration := last_time.to end
        compressed_size := size - last_size
        compression_message := ""
        if new_position != 0:
          compression_message = "$(((compressed_size * 1000.0 / (8 * PROGRESS_EVERY)).to_int + 0.1)/10.0)%"
          point := compression_message.index_of "."
          compression_message = compression_message.copy 0 point + 2
          compression_message += "%"
          logger.call "Pos $(%7d new_position), $(%6d best_bdiff_length) bits, $(%6d (duration/PROGRESS_EVERY).in_us)us/byte $compression_message"
        last_time = end
        last_size = size
  end_state := null
  actions.do:
    if not end_state or end_state.worse_than it:
      end_state = it
  return end_state

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

  static first_eight_bytes hash/ByteArray -> string:
    return "$(%02x hash[0])$(%02x hash[1])$(%02x hash[2])$(%02x hash[3])"

  stringify:
    return "0x$(%06x position)-0x$(%06x position + size - 1): Rolling:$(first_eight_bytes adler)"

  constructor .position .size .adler:

  static hash_number hash/ByteArray -> int:
    return hash[0] + (hash[1] << 8) + (hash[2] << 16) + (hash[3] << 24)

  adler_number -> int:
    return hash_number adler

  adler_match a/Adler32:
    other := a.get --destructive=false
    if other.size != adler.size: return false
    other.size.repeat:
      if other[it] != adler[it]: return false
    return true

  static get_sections bytes/OldData section_size/int -> Map:
    sections := {:}
    for pos := 0; pos < bytes.size; pos += section_size:
      if bytes.valid pos section_size:
        half_adler := Adler32
        two := ByteArray 2
        for i := 0; i < section_size and pos + i < bytes.size; i += 4:
          two[0] = bytes[pos + i + 2]
          two[1] = bytes[pos + i + 3]
          half_adler.add two

        section := Section pos section_size half_adler.get
        number := section.adler_number
        list := (sections.get number --init=: [])
        if list.size < 16 or (pos / section_size) & 0x1f == 0:
          list.add section

    return sections

class Writer_:
  new_bytes/ByteArray
  fd := null
  number_of_bits := 0
  accumulator := 0

  constructor .new_bytes:

  write_diff file end_state/Action --with_footer=true -> int:
    bdiff_size := 0
    fd = file

    count := 1

    action/Action? := end_state
    while action.predecessor != null:
      count++
      action = action.predecessor
    all_actions := List count
    action = end_state
    while action:
      count--
      all_actions[count] = action
      action = action.predecessor

    last_action := PadAction_ end_state
    all_actions.add last_action

    if with_footer:
      end_action := EndAction_ last_action
      all_actions.add end_action

    one_byte_buffer := ByteArray 1
    all_actions.do: | action |
      next_byte_boundary := round_up number_of_bits 8
      (action.emit_bits next_byte_boundary - number_of_bits).do: | to_output |
        accumulator <<= to_output.number_of_bits
        accumulator |= to_output.bits
        number_of_bits += to_output.number_of_bits
        while number_of_bits >= 8:
          byte := (accumulator >> (number_of_bits - 8)) & 0xff
          one_byte_buffer[0] = byte
          fd.write one_byte_buffer
          bdiff_size++
          number_of_bits -= 8
          accumulator &= (1 << number_of_bits) - 1
        extra_bytes := to_output.byte_array_count
        position := to_output.byte_array_start
        while extra_bytes-- != 0:
          accumulator <<= 8
          accumulator |= to_output.byte_array[position++]
          one_byte_buffer[0] = (accumulator >> number_of_bits) & 0xff
          fd.write one_byte_buffer
          bdiff_size++
          accumulator &= 0xff  // Avoid Smi overflow.
    if number_of_bits != 0:
      one_byte_buffer[0] = (accumulator << (8 - number_of_bits)) & 0xff
      fd.write one_byte_buffer
      bdiff_size++

    return bdiff_size
