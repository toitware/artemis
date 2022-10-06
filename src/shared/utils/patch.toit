// Copyright (C) 2020 Toitware ApS. All rights reserved.

import crypto.sha256 show *
import reader show *
import .patch_format

interface PatchWriter_:
  on_write data from/int=0 to/int=data.size -> none

interface PatchObserver extends PatchWriter_:
  on_size size/int -> none
  on_new_checksum checksum/ByteArray -> none
  on_checkpoint patch_position/int -> none

class Patcher:
  bitstream/BufferedReader ::= ?
  old_bytes/ByteArray
  byte_list ::= ?
  patch_position := ?
  old_position := 0
  new_position := 0
  accumulator_size := 0
  accumulator := 0
  byte_oriented := false
  diff_table ::= List DIFF_TABLE_SIZE: 0
  static DISPATCH_TABLE_SIZE_ ::= 0x100
  dispatch_bits ::= ByteArray DISPATCH_TABLE_SIZE_
  argument_bits ::= ByteArray DISPATCH_TABLE_SIZE_
  argument_offsets ::= ByteArray DISPATCH_TABLE_SIZE_
  temp_buffer ::= ByteArray 256
  out_checker ::= Sha256

  /// The optional byte_list argument is a version of the old_bytes
  /// ByteArray that has a [] argument.  This is needed for ByteArrays
  /// backed by instruction memory.  TODO: Fix so that all ByteArray
  /// operations work on instruction memory.
  constructor .bitstream .old_bytes .byte_list=old_bytes --patch_offset=0:
    patch_position = patch_offset
    init_

  // Returns success/failure if the patch is well formed.
  // Throws if the patch format is incorrect.
  patch observer/PatchObserver -> bool:
    // Patch file should start with a magic number:
    // 0b0111_1111         Metadata tag, ASCII DEL.
    // 'M'                 Magic number code, not ignorable.
    // 0x00 0x32           32 bits of payload.
    // 0x70 0x17 0xd1 0xff Magic number 0x7017d1ff at offset 5.
    ensure_bits_ 16
    // Stream should start either with the magic number or with a reset code,
    // which indicates a checkpoint in a stream where the decompression can be
    // resumed if it was interrupted.
    if accumulator != NON_IGNORABLE_METADATA + 'M' and
       accumulator != NON_IGNORABLE_METADATA + 'R':
      throw "INVALID_FORMAT"
    while true:
      ensure_bits_ 8
      index := accumulator >> (accumulator_size - 8)
      consume_bits_ dispatch_bits[index]
      argument := argument_offsets[index]
      bits := argument_bits[index]
      if bits != 0:
        argument += get_bits_ bits
      if index == 0b0111_1111:
        metadata_result := handle_metadata_
          argument & 0b1000_0000 != 0  // Ignorable.
          argument & 0b0111_1111       // Code.
          observer
        if metadata_result == true:
          return true // End of stream.
        if metadata_result == false:
          return false // Patch was not compatible with the old data.
      else if index <= 0b1110_1101: // Use diff table.
        diff_index := index < 0b1000_0000 ? 0 : argument
        repeats := index < 0b1000_0000 ? argument : 1
        copy_data diff_index repeats observer
        if diff_index > (byte_oriented ? 1 : 0):
          shift_diff_table_
            diff_index / 2
            diff_index
            diff_table[diff_index]
      else if index <= 0b1110_1111:  // Move cursor absolute byte/word mode.
        old_position = get_bits_ 24
        set_byte_oriented_ (argument == 1)
      else if index <= 0b1111_0011:  // New 8 bit entry in diff table.
        shift_diff_table_
          DIFF_TABLE_INSERTION
          DIFF_TABLE_SIZE - 1
          argument - 0x80
        copy_data DIFF_TABLE_INSERTION 1 observer
      else if index <= 0b1111_0111:  // New 16 bit entry in diff table.
        shift_diff_table_
          DIFF_TABLE_INSERTION
          DIFF_TABLE_SIZE - 1
          argument - 0x8000
        copy_data DIFF_TABLE_INSERTION 1 observer
      else if index <= 0b1111_1011:
        read_literals_ argument observer
      else if index <= 0b1111_1101:
        old_position += (argument << 1) - 1
      else if index <= 0b1111_1110:
        shift := argument - 0x80
        old_position += shift
        if shift == 0:
          // Byte align the input.
          ignore_bits_ accumulator_size & 7
      else:
        set_byte_oriented_ (not byte_oriented)

  // Check that have we output the same bits that the metadata sha hash
  // indicated we should.
  check_result new_expected_checksum/ByteArray -> none:
    checksum := out_checker.get
    assert: new_expected_checksum.size == checksum.size
    diff := 0
    checksum.size.repeat: diff |= checksum[it] ^ new_expected_checksum[it]
    if diff != 0: throw "ROUND TRIP FAILED"

  // Returns true if we are done.
  // Returns false if old_bytes is incompatible with this patch.
  // Throws if the patch format is unexpected.
  // Returns null in the normal case.
  handle_metadata_ ignorable/bool code/int observer/PatchObserver -> bool?:
    // Position in patch data stream in bits.  The metadata intro sequence is
    // 16 bits: 0b0111_1111 and the metadata code which is 8 bits.
    METADATA_INTRO_SIZE ::= 16
    SIZE_FIELD_SIZE ::= 16
    size := get_bits_ SIZE_FIELD_SIZE
    if ignorable:
      if code == 'S' and size == 38 * 8:  // 38 bytes of payload.
        // Sha checksum of old bytes.
        //   3 bytes of start address, big endian.
        //   3 bytes of length, big endian.
        //   32 bytes of Sha256 checksum.
        start := get_bits_ 24
        length := get_bits_ 24
        if start < 0 or length < 0 or start + length > old_bytes.size or start + length < start:
          return false
        actual_checksum := get_sha_ start start + length
        diff := 0
        32.repeat:
          diff |= actual_checksum[it] ^ (get_bits_ 8)
        if diff != 0:
          return false
        return null
      if code == 's' and size == 32 * 8:  // Expected Sha256 checksum of result.
        new_expected_checksum := ByteArray 32: get_bits_ 8
        observer.on_new_checksum new_expected_checksum
        return null
      if code == 'n':
        total_new_size := get_bits_ size
        observer.on_size total_new_size
        return null
      // Ignore other ignorable metadata for now.
      ignore_bits_ size
      return null
    else:
      // Not ignorable.
      if code == 'M':
        // Magic number
        if size != 32 or
           (get_bits_ 16) != 0x7017 or  // 0x7017d1ff Toit-diff.
           (get_bits_ 16) != 0xd1ff:
          throw "INVALID_FORMAT"
        return null
      if code == 'E':  // End of patch.
        ignore_bits_ size
        return true
      if code == 'R':  // Reset state.
        patch_position_before_metadata := patch_position * BITS_PER_BYTE - METADATA_INTRO_SIZE - SIZE_FIELD_SIZE - accumulator_size
        if patch_position_before_metadata == (round_up patch_position_before_metadata BITS_PER_BYTE):
          observer.on_checkpoint patch_position_before_metadata / BITS_PER_BYTE
        ignore_bits_ size
        diff_table.size.repeat: diff_table[it] = 0
        byte_oriented = false
        old_position = 0
        return null
      throw "INVALID_FORMAT"  // Didn't recognize non-ignorable metadata.

  /// Can get a SHA256 hash of a byte array that is in instruction memory,
  /// where only 32 bit accesses are allowed.
  get_sha_ from/int to/int -> ByteArray:
    // The patch file should not contain checksums of unaligned part of the old
    // image.
    if (from | to) & 3 != 0: throw "INVALID_FORMAT"
    length ::= to - from
    summer ::= Sha256
    buffer ::= ByteArray 128
    List.chunk_up from to buffer.size: | chunk_from chunk_to chunk_size |
      // Replace will only use 32 bit operations.
      buffer.replace 0 old_bytes chunk_from chunk_to
      summer.add buffer 0 chunk_size
    return summer.get

  copy_data_no_diff_ byte_count/int writer/PatchWriter_ -> none:
    assert: (old_position | byte_count) & 3 == 0  // Because of instruction memory.
    List.chunk_up old_position old_position + byte_count temp_buffer.size: | from to size |
      assert: (from | to) & 3 == 0  // Because of instruction memory.
      temp_buffer.replace 0 old_bytes from to
      writer.on_write temp_buffer 0 size
      out_checker.add temp_buffer 0 size
    old_position += byte_count
    new_position += byte_count

  copy_data index/int repeats/int writer/PatchWriter_ -> none:
    diff := diff_table[index]
    if diff == 0:
      byte_count := repeats * (byte_oriented ? 1 : 4)
      if old_position & 3 != 0:
        edge_bytes := min byte_count (4 - (old_position & 3))
        copy_data_diff_ diff edge_bytes --by_bytes=true writer
        byte_count -= edge_bytes
      aligned := byte_count & ~3
      if aligned != 0:
        copy_data_no_diff_ aligned writer
      if aligned != byte_count:
        copy_data_diff_ diff (byte_count - aligned) --by_bytes=true writer
    else:
      copy_data_diff_ diff repeats --by_bytes=byte_oriented writer

  copy_data_diff_ diff/int repeats/int --by_bytes/bool writer/PatchWriter_ -> none:
    if by_bytes:
      List.chunk_up 0 repeats temp_buffer.size: | _ _ chunk_size |
        chunk_size.repeat:
          byte := byte_list[old_position + it]
          temp_buffer[it] = (byte + diff) & 0xff
        old_position += chunk_size
        writer.on_write temp_buffer 0 chunk_size
        out_checker.add temp_buffer 0 chunk_size
        new_position += chunk_size
    else:
      List.chunk_up 0 repeats * 4 temp_buffer.size: | _ _ chunk_size |
        for i := 0; i < chunk_size; i += 4:
          word := byte_list[old_position] + (byte_list[old_position + 1] << 8) + (byte_list[old_position + 2] << 16) + (byte_list[old_position + 3] << 24)
          old_position += 4
          new_position += 4
          word += diff
          temp_buffer[i] = word & 0xff
          temp_buffer[i + 1] = (word >> 8) & 0xff
          temp_buffer[i + 2] = (word >> 16) & 0xff
          temp_buffer[i + 3] = (word >> 24) & 0xff
        writer.on_write temp_buffer 0 chunk_size
        out_checker.add temp_buffer 0 chunk_size

  ensure_bits_ bits/int -> none:
    while accumulator_size < bits:
      accumulator = (accumulator << BITS_PER_BYTE) | bitstream.read_byte
      accumulator_size += BITS_PER_BYTE
      patch_position++

  consume_bits_ bits/int:
    assert: accumulator_size >= bits
    accumulator_size -= bits
    accumulator &= (1 << accumulator_size) - 1

  ignore_bits_ bits/int:
    List.chunk_up 0 bits 16: | _ _ increment |
      get_bits_ increment
      bits -= increment

  get_bits_ bits/int:
    ensure_bits_ bits
    result := accumulator >> (accumulator_size - bits)
    consume_bits_ bits
    return result

  /// Move a chunk of the diff table from $from to $to by one.
  /// Insert $insert into the space made available.
  shift_diff_table_ from/int to/int insert/int:
    for i := to; i > from; i--:
      diff_table[i] = diff_table[i - 1]
    diff_table[from] = insert

  read_literals_ count/int writer/PatchWriter_ -> none:
    bytes := count * (byte_oriented ? 1 : 4)
    old_position += bytes
    new_position += bytes
    for i := 0; i < bytes; i++:
      if accumulator_size == 0 and bytes - i > 3:
        // We are byte aligned on the input, so we can do this simpler.
        // This causes a ByteArray allocation so we don't do it unless we hope
        // to get at least 4 bytes.
        byte_array := bitstream.read --max_size=(bytes - i)
        patch_position += byte_array.size
        writer.on_write byte_array 0 byte_array.size
        out_checker.add byte_array
        i += byte_array.size - 1  // Minus 1 because the loop will increment it.
      else:
        temp_buffer[0] = get_bits_ BITS_PER_BYTE
        writer.on_write temp_buffer 0 1
        out_checker.add temp_buffer 0 1

  set_byte_oriented_ value/bool -> none:
    byte_oriented = value
    if value and diff_table[0] != 0:
      // Make sure the 0th entry is zero in byte mode.
      DIFF_TABLE_SIZE.repeat:
        if diff_table[it] == 0:
          shift_diff_table_ 0 it 0
          return
      // No zero found.
      shift_diff_table_ 0 DIFF_TABLE_SIZE - 1 0

  init_:
    // Variable length prefix bit codes.  Some seem to overlap but that's
    // because the last few entries of an xx are unused.  All values in this
    // table are constant and in byte range so that it can be represented as a
    // byte array at runtime and in the program image.
    COMMANDS ::= #[
      2, 0b00, 0, 1,           // 00        Diff index 0 1.
      2, 0b01, 2, 3,           // 01xx      Diff index 0 3-5, xx != 0b11
      4, 0b0111, 4, 11,        // 0111_xxxx Diff index 0 11-23, xxxx <= 1100
      8, 0b0111_1101, 8, 47,   // 0111_1101 Diff index 0 47-302.
      8, 0b0111_1110, 16, 255, // 0111_1110 Diff index 0 255-65790
      8, 0b0111_1111, 8, 0,    // 0111_1111 Metadata.
      3, 0b100, 0, 1,          // 100       Diff index 1.
      3, 0b101, 1, 2,          // 101x      Diff index 2-3.
      3, 0b110, 2, 4,          // 110x_x    Diff index 4-7.
      4, 0b1110, 4, 8,         // 1110_xxxx Diff index 8-21, xxxx != 0b111?
      7, 0b1110_111, 1, 0,     // 1110_111x Set cursor and word/byte mode.
      6, 0b1111_00, 8, 0,      // 1111_00   New diff table entry 8 bit
      6, 0b1111_01, 16, 0,     // 1111_01   New diff table entry 16 bit
      6, 0b1111_10, 2, 1,      // 1111_10xx Overwrite 1-3 bytes/words, xx != 0b11.
      8, 0b1111_1011, 8, 7,    // 1111_1011 Overwrite 7-262 bytes/words
      7, 0b1111_110, 1, 0,     // 1111_110x Move cursor by -1 or 1.
      8, 0b1111_1110, 8, 0,    // 1111_1110 Move cursor by -128-127.
                               //           (Move cursor 0 means byte-pad data stream.)
      8, 0b1111_1111, 0, 0,    // 1111_1111 Switch between byte and word modes.
      // Dispatch optimizations that mean we can consume more than one code in
      // one go:
      4, 0b0000, 0, 2,         // 00, 00 is   1 + 1 = 2 items using diff index 0
      6, 0b0110_00, 0, 6,      // 0110, 00 is 5 + 1 = 6 items using diff index 0
      8, 0b0110_0000, 0, 7,    // 0110, 00, 00 is 5 + 1 + 1 = 7 items
      8, 0b0110_0100, 0, 8,    // 0110, 0100   is 5 + 3     = 8 times
      8, 0b0110_0101, 0, 9,    // 0110, 0101   is 5 + 4     = 9 times
      8, 0b0110_0110, 0, 10,   // 0110, 0110   is 5 + 5     = 10 times

      // After a metadata code there are 24 bits of argument.  The first bit is
      // an "ignorable" bit that tells you whether the patcher can ignore the
      // metadata code if it doesn't understand it.  The next 7 bits are a
      // command code which tells you what the rest is, and the next 16 bits
      // are a size field, in bits, that tells you how much data there is - up
      // to 8k. Currently defined command codes:
      // Code Ignore Meaning.
      // 'E'  N      End.
      // 'N'  Y      Nop. Variable sized payload.
      // 'R'  N      Reset. The diff table, old position & byte mode are reset.
      // 'S'  Y      Old bytes Sha256 checksum. 3-byte start, 3-byte length, 32 bytes payload.
      // 's'  Y      New bytes Sha256 checksum. 32 bytes payload.
      // 'n'  Y      Size of new data in bytes, variable length big-endian payload.
      // 'M'  Y      Magic number 0x70 0x17 0xd1 0xff
    ]
    for i := 0; i < COMMANDS.size; i += 4:
      command_bits := COMMANDS[i]
      shift := 8 - command_bits
      start := COMMANDS[i + 1] << shift
      (1 << shift).repeat:
        idx := start + it
        dispatch_bits[idx] = command_bits
        argument_bits[idx] = COMMANDS[i + 2]
        argument_offsets[idx] = COMMANDS[i + 3]
