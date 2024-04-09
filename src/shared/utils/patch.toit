// Copyright (C) 2020 Toitware ApS. All rights reserved.

import crypto.sha256 show *
import io
import io show LITTLE-ENDIAN
import system show BITS-PER-BYTE
import system.firmware

import .patch-format

PATCH-READING-FAILED-EXCEPTION ::= "PATCH_READING_FAILED"

interface PatchWriter_:
  on-write data from/int=0 to/int=data.size -> none

interface PatchObserver extends PatchWriter_:
  on-size size/int -> none
  on-new-checksum checksum/ByteArray -> none
  on-checkpoint patch-position/int -> none

class Patcher:
  bitstream/PatchReader_
  old/firmware.FirmwareMapping?
  patch-position := ?
  old-position := 0
  new-position := 0
  accumulator-size := 0
  accumulator := 0
  byte-oriented := false
  diff-table ::= List DIFF-TABLE-SIZE: 0
  static DISPATCH-TABLE-SIZE_ ::= 0x100
  dispatch-bits ::= ByteArray DISPATCH-TABLE-SIZE_
  argument-bits ::= ByteArray DISPATCH-TABLE-SIZE_
  argument-offsets ::= ByteArray DISPATCH-TABLE-SIZE_
  temp-buffer ::= ByteArray 256
  out-checker ::= Sha256

  constructor reader/io.Reader old --patch-offset=0:
    bitstream = PatchReader_ reader
    this.old = (old is ByteArray) ? (firmware.FirmwareMapping_ old) : old
    patch-position = patch-offset
    init_

  // Returns success/failure if the patch is well formed.
  // Throws if the patch format is incorrect.
  patch observer/PatchObserver -> bool:
    // Patch file should start with a magic number:
    // 0b0111_1111         Metadata tag, ASCII DEL.
    // 'M'                 Magic number code, not ignorable.
    // 0x32                32 bits of payload.
    // 0x70 0x17 0xd1 0xff Magic number 0x7017d1ff at offset 4.
    ensure-bits_ 16
    // Stream should start either with the magic number or with a reset code,
    // which indicates a checkpoint in a stream where the decompression can be
    // resumed if it was interrupted.
    if accumulator != NON-IGNORABLE-METADATA + 'M' and
       accumulator != NON-IGNORABLE-METADATA + 'R':
      throw "INVALID_FORMAT"
    while true:
      ensure-bits_ 8
      index := accumulator >> (accumulator-size - 8)
      consume-bits_ dispatch-bits[index]
      argument := argument-offsets[index]
      bits := argument-bits[index]
      if bits != 0:
        argument += get-bits_ bits
      if index == 0b0111_1111:
        metadata-result := handle-metadata_
          argument & 0b1000_0000 != 0  // Ignorable.
          argument & 0b0111_1111       // Code.
          observer
        if metadata-result == true:
          return true // End of stream.
        if metadata-result == false:
          return false // Patch was not compatible with the old data.
      else if index <= 0b1110_1101: // Use diff table.
        diff-index := index < 0b1000_0000 ? 0 : argument
        repeats := index < 0b1000_0000 ? argument : 1
        copy-data diff-index repeats observer
        if diff-index > (byte-oriented ? 1 : 0):
          shift-diff-table_
            diff-index / 2
            diff-index
            diff-table[diff-index]
      else if index <= 0b1110_1111:  // Move cursor absolute byte/word mode.
        old-position = get-bits_ 24
        set-byte-oriented_ (argument == 1)
      else if index <= 0b1111_0011:  // New 8 bit entry in diff table.
        shift-diff-table_
          DIFF-TABLE-INSERTION
          DIFF-TABLE-SIZE - 1
          argument - 0x80
        copy-data DIFF-TABLE-INSERTION 1 observer
      else if index <= 0b1111_0111:  // New 16 bit entry in diff table.
        shift-diff-table_
          DIFF-TABLE-INSERTION
          DIFF-TABLE-SIZE - 1
          argument - 0x8000
        copy-data DIFF-TABLE-INSERTION 1 observer
      else if index <= 0b1111_1011:
        read-literals_ argument observer
      else if index <= 0b1111_1101:
        old-position += (argument << 1) - 1
      else if index <= 0b1111_1110:
        shift := argument - 0x80
        old-position += shift
        if shift == 0:
          // Byte align the input.
          ignore-bits_ accumulator-size & 7
      else:
        set-byte-oriented_ (not byte-oriented)
    yield  // Give other tasks, like the watchdog provider, a chance to run.

  // Check that have we output the same bits that the metadata sha hash
  // indicated we should.
  check-result new-expected-checksum/ByteArray -> none:
    checksum := out-checker.get
    assert: new-expected-checksum.size == checksum.size
    diff := 0
    checksum.size.repeat: diff |= checksum[it] ^ new-expected-checksum[it]
    if diff != 0: throw "ROUND TRIP FAILED"

  // Returns true if we are done.
  // Returns false if old firmware is incompatible with this patch.
  // Throws if the patch format is unexpected.
  // Returns null in the normal case.
  handle-metadata_ ignorable/bool code/int observer/PatchObserver -> bool?:
    // Position in patch data stream in bits.  The metadata intro sequence is
    // 16 bits: 0b0111_1111 and the metadata code which is 8 bits.
    METADATA-INTRO-SIZE ::= 16
    // 2 bit field gives the size of the size field, 6, 14, 22, or 30 bits.
    METADATA-SIZE-FIELD-SIZE ::= 2
    size-field-size ::= (get-bits_ METADATA-SIZE-FIELD-SIZE) * 8 + 6
    size := get-bits_ size-field-size
    if ignorable:
      if code == 'S' and size == 38 * 8:  // 38 bytes of payload.
        // Sha checksum of old bytes.
        //   3 bytes of start address, big endian.
        //   3 bytes of length, big endian.
        //   32 bytes of Sha256 checksum.
        start := get-bits_ 24
        length := get-bits_ 24
        if start < 0 or length < 0 or start + length > old.size or start + length < start:
          return false
        actual-checksum := get-sha_ start start + length
        diff := 0
        32.repeat:
          diff |= actual-checksum[it] ^ (get-bits_ 8)
        if diff != 0:
          return false
        return null
      if code == 's' and size == 32 * 8:  // Expected Sha256 checksum of result.
        new-expected-checksum := ByteArray 32: get-bits_ 8
        observer.on-new-checksum new-expected-checksum
        return null
      if code == 'n':
        total-new-size := get-bits_ size
        observer.on-size total-new-size
        return null
      // Ignore other ignorable metadata for now.
      ignore-bits_ size
      return null
    else:
      // Not ignorable.
      if code == 'M':
        // Magic number
        if size != 32 or
           (get-bits_ 16) != 0x7017 or  // 0x7017d1ff Toit-diff.
           (get-bits_ 16) != 0xd1ff:
          throw "INVALID_FORMAT"
        return null
      if code == 'Z' or code == 'L':  // Output zeros or literal bytes.
        byte := 0
        if code == 'L':
          byte = get-bits_ 8
          size -= 8
        repeats := get-bits_ size
        if not byte-oriented: repeats *= 4
        temp-buffer.fill byte
        List.chunk-up 0 repeats temp-buffer.size: | _ _ chunk-size |
          observer.on-write temp-buffer 0 chunk-size
          out-checker.add temp-buffer 0 chunk-size
        new-position += repeats
        return null
      if code == 'E':  // End of patch.
        ignore-bits_ size
        return true
      if code == 'R':  // Reset state.
        patch-position-before-metadata := patch-position * BITS-PER-BYTE - METADATA-INTRO-SIZE - size-field-size - METADATA-SIZE-FIELD-SIZE - accumulator-size
        if patch-position-before-metadata == (round-up patch-position-before-metadata BITS-PER-BYTE):
          observer.on-checkpoint patch-position-before-metadata / BITS-PER-BYTE
        ignore-bits_ size
        diff-table.size.repeat: diff-table[it] = 0
        byte-oriented = false
        old-position = 0
        return null
      throw "INVALID_FORMAT"  // Didn't recognize non-ignorable metadata.

  /// Can get a SHA256 hash of a byte array that is in instruction memory,
  /// where only 32 bit accesses are allowed.
  get-sha_ from/int to/int -> ByteArray:
    summer ::= Sha256
    buffer ::= ByteArray 128
    List.chunk-up from to buffer.size: | chunk-from chunk-to chunk-size |
      // Copy will only use 32 bit operations.
      old.copy chunk-from chunk-to --into=buffer
      summer.add buffer 0 chunk-size
    return summer.get

  copy-data-no-diff_ byte-count/int writer/PatchWriter_ -> none:
    from := old-position
    to := old-position + byte-count
    List.chunk-up from to temp-buffer.size: | chunk-from chunk-to chunk-size |
      // Copy will only use 32 bit operations.
      old.copy chunk-from chunk-to --into=temp-buffer
      writer.on-write temp-buffer 0 chunk-size
      out-checker.add temp-buffer 0 chunk-size
    old-position += byte-count
    new-position += byte-count

  copy-data index/int repeats/int writer/PatchWriter_ -> none:
    diff := diff-table[index]
    if diff == 0:
      byte-count := repeats * (byte-oriented ? 1 : 4)
      if not old-position.is-aligned 4:
        edge-bytes := min byte-count ((round-up old-position 4) - old-position)
        copy-data-diff_ diff edge-bytes --by-bytes=true writer
        byte-count -= edge-bytes
      aligned := round-down byte-count 4
      copy-data-no-diff_ aligned writer
      copy-data-diff_ diff (byte-count - aligned) --by-bytes=true writer
    else:
      copy-data-diff_ diff repeats --by-bytes=byte-oriented writer

  copy-data-diff_ diff/int repeats/int --by-bytes/bool writer/PatchWriter_ -> none:
    if by-bytes:
      List.chunk-up 0 repeats temp-buffer.size: | _ _ chunk-size |
        chunk-size.repeat:
          byte := old[old-position + it]
          temp-buffer[it] = (byte + diff) & 0xff
        old-position += chunk-size
        writer.on-write temp-buffer 0 chunk-size
        out-checker.add temp-buffer 0 chunk-size
        new-position += chunk-size
    else:
      List.chunk-up 0 repeats * 4 temp-buffer.size: | _ _ chunk-size |
        for i := 0; i < chunk-size; i += 4:
          // Can't use LITTLE_ENDIAN because old is not a real byte array.
          word := old[old-position] + (old[old-position + 1] << 8) + (old[old-position + 2] << 16) + (old[old-position + 3] << 24)
          old-position += 4
          new-position += 4
          word += diff
          LITTLE-ENDIAN.put-uint32 temp-buffer i word
        writer.on-write temp-buffer 0 chunk-size
        out-checker.add temp-buffer 0 chunk-size

  ensure-bits_ bits/int -> none:
    while accumulator-size < bits:
      accumulator = (accumulator << BITS-PER-BYTE) | bitstream.read-byte
      accumulator-size += BITS-PER-BYTE
      patch-position++

  consume-bits_ bits/int:
    assert: accumulator-size >= bits
    accumulator-size -= bits
    accumulator &= (1 << accumulator-size) - 1

  ignore-bits_ bits/int:
    List.chunk-up 0 bits 16: | _ _ increment |
      get-bits_ increment
      bits -= increment

  get-bits_ bits/int:
    if bits == 0: return 0
    ensure-bits_ bits
    result := accumulator >> (accumulator-size - bits)
    consume-bits_ bits
    return result

  /// Move a chunk of the diff table from $from to $to by one.
  /// Insert $insert into the space made available.
  shift-diff-table_ from/int to/int insert/int:
    for i := to; i > from; i--:
      diff-table[i] = diff-table[i - 1]
    diff-table[from] = insert

  read-literals_ count/int writer/PatchWriter_ -> none:
    bytes := count * (byte-oriented ? 1 : 4)
    old-position += bytes
    new-position += bytes
    for i := 0; i < bytes; i++:
      if accumulator-size == 0 and bytes - i > 3:
        // We are byte aligned on the input, so we can do this simpler.
        // This causes a ByteArray allocation so we don't do it unless we hope
        // to get at least 4 bytes.
        byte-array := bitstream.read --max-size=(bytes - i)
        // We must hand the bytes to the 'out_checker' and get the size of the
        // byte array before we call 'on_write'. The writer may neuter the byte
        // array, so after the call it might be empty.
        out-checker.add byte-array
        size := byte-array.size
        // Now write the bytes.
        writer.on-write byte-array 0 size
        patch-position += size
        i += size - 1  // Minus 1 because the loop will increment it.
      else:
        temp-buffer[0] = get-bits_ BITS-PER-BYTE
        writer.on-write temp-buffer 0 1
        out-checker.add temp-buffer 0 1

  set-byte-oriented_ value/bool -> none:
    byte-oriented = value
    if value and diff-table[0] != 0:
      // Make sure the 0th entry is zero in byte mode.
      DIFF-TABLE-SIZE.repeat:
        if diff-table[it] == 0:
          shift-diff-table_ 0 it 0
          return
      // No zero found.
      shift-diff-table_ 0 DIFF-TABLE-SIZE - 1 0

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
      command-bits := COMMANDS[i]
      shift := 8 - command-bits
      start := COMMANDS[i + 1] << shift
      (1 << shift).repeat:
        idx := start + it
        dispatch-bits[idx] = command-bits
        argument-bits[idx] = COMMANDS[i + 2]
        argument-offsets[idx] = COMMANDS[i + 3]

class PatchReader_:
  reader_/io.Reader
  cursor_/int := 0
  bytes_/ByteArray? := null

  constructor .reader_:

  read-byte -> int:
    bytes := ensure-bytes_
    return bytes[cursor_++]

  read --max-size/int -> ByteArray:
    bytes := ensure-bytes_
    from := cursor_
    to := from + (min max-size (bytes.size - from))
    result := bytes[from..to]
    cursor_ = to
    return result

  ensure-bytes_ -> ByteArray:
    bytes := bytes_
    if bytes:
      // Check if we have already moved the cursor all the way
      // to the end of the bytes (thus consuming them). If not,
      // we return the bytes and let the caller only look from
      // the cursor and forward.
      if cursor_ < bytes.size: return bytes
      assert: cursor_ == bytes.size
      bytes_ = bytes = null
    try:
      bytes = reader_.read
    finally:
      // We convert any read exception into a recognizable
      // exception that we can reason about in outer layers.
      if not bytes: throw PATCH-READING-FAILED-EXCEPTION
    bytes_ = bytes
    cursor_ = 0
    return bytes
