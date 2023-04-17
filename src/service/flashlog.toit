// Copyright (C) 2023 Toitware ApS. All rights reserved.

import binary show LITTLE_ENDIAN
import crypto.crc
import system.storage

import .pkg_artemis_src_copy.api as api

class FlashLog:
  static HEADER_MARKER_OFFSET_   ::= 0
  static HEADER_SN_OFFSET_       ::= 4 + HEADER_MARKER_OFFSET_
  static HEADER_CHECKSUM_OFFSET_ ::= 4 + HEADER_SN_OFFSET_
  static HEADER_COUNT_OFFSET_    ::= 4 + HEADER_CHECKSUM_OFFSET_
  static HEADER_SIZE_            ::= 2 + HEADER_COUNT_OFFSET_

  static MARKER_ ::= 0x21_CE_A9_66

  region_/storage.Region
  size_/int
  size_per_page_/int

  // One page buffer. Re-used whenever possible.
  buffer_/ByteArray? := ?

  // Cursors for read and write.
  read_page_/int := -1
  write_page_/int := -1
  write_offset_/int := -1

  // ...
  prevalidated_/int := 0

  // TODO(kasper): This should be cleaned up. It might make sense
  // to combine the FlashLog and the ChannelResource more somehow.
  usage_/int := 0

  constructor region/storage.Region:
    if not region.write_can_clear_bits:
      throw "Must be able to clear bits"
    if region.erase_value != 0xff:
      throw "Must erase to all set bits"
    if region.size <= region.erase_granularity:
      throw "Must have space for two pages"
    region_ = region
    size_ = region.size
    size_per_page_ = region.erase_granularity
    buffer_ = ByteArray size_per_page_
    with_buffer_: ensure_valid_ it

  acquire -> int:
    return ++usage_

  release -> int:
    usage := usage_ - 1
    usage_ = usage
    if usage == 0: region_.close
    return usage

  dump -> none:
    with_buffer_ --if_absent=(: ByteArray size_per_page_): | buffer/ByteArray |
      dump_ buffer

  append bytes/ByteArray -> none:
    // We compute the size by counting the number of bits we need.
    // The first byte is special since it only encodes 6 bits, so
    // we pull that out of the computation (add 1), so we end up
    // with something like (bits - 6) / 7. Since we want to do a
    // ceiling division by 7, we get (bits - 6 + 7 - 1) / 7 and
    // end up with the nicer looking:
    size := 1 + (bytes.size << 3) / 7
    if size > size_per_page_ - HEADER_SIZE_: throw "Bad Argument"

    with_buffer_ --if_absent=(: ByteArray size): | buffer/ByteArray |
      // Check to see if we have to advance the write page.
      next := write_page_ + size_per_page_
      if write_offset_ + size > next:
        if next >= size_: next = 0

        // It is rather unfortunate that we have to reallocate the
        // buffer here if it isn't big enough. This happens when
        // we need to advance the write page while we're still busy
        // reading another page.
        if buffer.size < size_per_page_: buffer = ByteArray size_per_page_

        // Read the whole page, so we can get the sequence
        // number and the count. If the page isn't committed
        // we will need to decode all entries to compute the
        // correct sequence number for the next write page.
        region_.read --from=write_page_ buffer
        sn := LITTLE_ENDIAN.uint32 buffer HEADER_SN_OFFSET_
        count := LITTLE_ENDIAN.uint16 buffer HEADER_COUNT_OFFSET_

        // Compute the next sequence number.
        next_sn := (count == 0xffff)
            ? decode_all_ buffer write_page_ --commit: null
            : SN.next sn --increment=count

        // Advance the write page.
        advance_write_page_ buffer next_sn
        assert: is_valid_ buffer

      encoded_size := encode_next_ buffer bytes
      assert: size == encoded_size
      region_.write --from=write_offset_ buffer[..size]
      write_offset_ += size

  has_more -> bool:
    // TODO(kasper): Handle reading from ack'ed pages. We
    // have an invariant that makes it impossible to get
    // to this point, but we should handle it gracefully.
    with_buffer_: | buffer/ByteArray |
      region_.read --from=read_page_ buffer[.. HEADER_SIZE_ + 1]
      decode_next_ buffer HEADER_SIZE_: return true
    return false

  /**
  Reads from the first unacknowledged page.
  */
  read [block] -> none:
    with_buffer_: | buffer/ByteArray |
      commit_and_read_ buffer read_page_: | sn count | null
      decode buffer block

  /**
  Decodes the given buffer.
  */
  decode buffer/ByteArray [block] -> none:
    decode_all_ buffer -1: | from to sn |
      // We copy the section because we're reusing buffers
      // and it is very unfortunate to change the sections
      // we have already handed out.
      block.call (buffer.copy from to) sn

  /**
  Reads the page $peek pages after the read page
    into the given buffer.

  Returns a list with the following elements:
    [0]: page first sequence number  / int
    [1]: page start cursor           / int?
    [2]: page element count          / int
    [3]: page buffer                 / ByteArray
  */
  read_page buffer/ByteArray --peek/int=0 -> List:
    if peek < 0 or buffer.size != size_per_page_:
      throw "Bad Argument"
    prevalidated := prevalidated_
    // Run through the pages and skip or validate the ones
    // that come before the page we're interested in.
    page := read_page_
    next_sn := null
    peek.repeat: | index/int |
      // If we reach the write page while running through
      // the pages we're not interested in, we're done.
      if page == write_page_:
        region_.read --from=page buffer[..HEADER_SIZE_]
        sn := LITTLE_ENDIAN.uint32 buffer HEADER_SN_OFFSET_
        return [sn, null, 0, buffer]
      current := page
      page += size_per_page_
      if page >= size_: page = 0
      if index >= prevalidated:
        is_committed_page_ current buffer: | sn is_acked count |
          if index == prevalidated or sn == next_sn:
            next_sn = SN.next sn --increment=count
            continue.repeat
        // Found uncommitted or wrong page. This shouldn't
        // happen so we reset and tell the user that something
        // was terribly wrong.
        repair_reset_ buffer SN.new
        throw "INVALID_STATE"
    prevalidated_ = max peek prevalidated
    commit_and_read_ buffer page: | sn count |
      cursor := count == 0 ? null : HEADER_SIZE_
      return [sn, cursor, count, buffer]
    unreachable

  // TODO(kasper): Allow passing the buffer in from the outside
  // so we can reuse the one the client already has?
  acknowledge sn/int -> none:
    with_buffer_: | buffer/ByteArray |
      is_committed_page_ read_page_ buffer: | sn_ is_acked count |
        next_sn := SN.next sn_ --increment=count
        last_sn := SN.previous next_sn
        if sn != last_sn: throw "Bad Argument"

        // Set the count to zero to mark this as acknowledged.
        if not is_acked:
          region_.write --from=(read_page_ + HEADER_COUNT_OFFSET_) #[0, 0]

        advance_read_page_ buffer next_sn
        prevalidated_ = max 0 (prevalidated_ - 1)
        assert: is_valid_ buffer
        return
    throw "Cannot acknowledge unread page"

  reset -> bool:
    read_page_ = -1
    write_page_ = -1
    write_offset_ = -1
    return with_buffer_: ensure_valid_ it

  // ------------------------------------------------------------------------

  with_buffer_ [block] -> any:
    return with_buffer_ block --if_absent=: throw "INVALID_STATE"

  with_buffer_ [block] [--if_absent] -> any:
    original := buffer_
    buffer_ = null
    try:
      buffer := original or if_absent.call
      return block.call buffer
    finally:
      if original: buffer_ = original

  /**
  Calls the $block with the first sequence number in the
    page and the element count.
  */
  commit_and_read_ buffer/ByteArray page/int [block] -> none:
    // TODO(kasper): Handle reading from ack'ed pages. We
    // have an invariant that makes it impossible to get
    // to this point, but we should handle it gracefully.

    // TODO(kasper): We shouldn't be allowed to read
    // beyond the write page. Can we check that here
    // or do we need to do it outside?

    region_.read --from=page buffer
    sn := LITTLE_ENDIAN.uint32 buffer HEADER_SN_OFFSET_
    count := LITTLE_ENDIAN.uint16 buffer HEADER_COUNT_OFFSET_
    if count != 0xffff:
      // Already committed. We're done.
      block.call sn count
      return

    // We avoid committing empty pages, so we can tell
    // if we did by looking at whether we decoded any
    // entries from the page.
    count = 0
    decode_all_ buffer page --commit: count++
    if count > 0:
      if page == write_page_:
        write_offset_ = write_page_ + size_per_page_
        // If we've decoded any entries to commit the
        // page, we've modified the buffer. Read it again.
        region_.read --from=page buffer
    block.call sn count

  advance_read_page_ buffer/ByteArray sn/int -> none:
    // Don't go beyond the write page.
    if read_page_ == write_page_:
      advance_write_page_ buffer sn
      read_page_ = write_page_
      return

    read_page_ += size_per_page_
    if read_page_ >= size_: read_page_ = 0

    is_committed_page_ read_page_ buffer: | snx is_acked count |
      if is_acked or snx != sn: repair_ buffer
      return
    is_uncommitted_page_ read_page_ buffer: | snx |
      if snx != sn: repair_ buffer
      return
    repair_ buffer

  advance_write_page_ buffer/ByteArray sn/int -> none:
    next := write_page_ + size_per_page_
    if next >= size_: next = 0

    // Don't go into the read page.
    if next == read_page_: throw "OUT_OF_BOUNDS"

    // Clear the page and start writing into it!
    region_.erase --from=next --to=next + size_per_page_
    assert: HEADER_MARKER_OFFSET_ == 0 and HEADER_SN_OFFSET_ == 4
    LITTLE_ENDIAN.put_uint32 buffer HEADER_MARKER_OFFSET_ MARKER_
    LITTLE_ENDIAN.put_uint32 buffer HEADER_SN_OFFSET_ sn
    region_.write --from=(next + HEADER_MARKER_OFFSET_) buffer[.. HEADER_SN_OFFSET_ + 4]
    write_page_ = next
    write_offset_ = next + HEADER_SIZE_

  // TODO(kasper): Maybe let page only be set when commit is?
  decode_all_ buffer/ByteArray page/int [block] --commit/bool=false -> int:
    sn := LITTLE_ENDIAN.uint32 buffer HEADER_SN_OFFSET_
    count := 0
    cursor := HEADER_SIZE_
    while cursor < size_per_page_:
      cursor = decode_next_ buffer cursor: | from to |
        count++
        block.call from to sn
        sn = SN.next sn

    if commit and count > 0:
      region_.read --from=page buffer
      assert: (LITTLE_ENDIAN.uint16 buffer HEADER_COUNT_OFFSET_) == 0xffff
      assert: (LITTLE_ENDIAN.uint32 buffer HEADER_CHECKSUM_OFFSET_) == 0xffff_ffff
      crc32 := crc.Crc32
      crc32.add buffer
      // Write the count and checksum together.
      assert: HEADER_COUNT_OFFSET_ == HEADER_CHECKSUM_OFFSET_ + 4
      LITTLE_ENDIAN.put_uint32 buffer 0 crc32.get_as_int
      LITTLE_ENDIAN.put_uint16 buffer 4 count
      region_.write --from=(page + HEADER_CHECKSUM_OFFSET_) buffer[..6]
    return sn

  decode_count_all_ buffer/ByteArray -> int:
    // TODO(kasper): Maybe specialize the call to decode_next_?
    count := 0
    cursor := HEADER_SIZE_
    while cursor < size_per_page_:
      cursor = decode_next_ buffer cursor: | from to |
        count++
    return count

  decode_next_ buffer/ByteArray start/int [block] -> int:
    cursor := start
    end := cursor
    acc := buffer[cursor++]
    if acc == 0xff: return size_per_page_

    bits := 6
    acc &= 0x3f
    while true:
      while bits < 8:
        next := (cursor >= buffer.size) ? 0xff : buffer[cursor]
        if (next & 0x80) != 0:
          block.call start end
          return next == 0xff ? size_per_page_ : cursor
        acc |= (next << bits)
        bits += 7
        cursor++
      buffer[end++] = (acc & 0xff)
      acc >>= 8
      bits -= 8

  encode_next_ buffer/ByteArray bytes/ByteArray -> int:
    assert: not bytes.is_empty
    acc := bytes[0]
    buffer[0] = 0x80 | (acc & 0x3f)
    acc >>= 6
    bits := 2
    size := 1

    for i := 1; i < bytes.size; i++:
      acc |= (bytes[i] << bits)
      bits += 8
      while bits >= 7:
        buffer[size++] = acc & 0x7f
        acc >>= 7
        bits -= 7
    if bits > 0: buffer[size++] = acc
    return size

  ensure_valid_ buffer/ByteArray -> bool:
    if is_valid_ buffer: return false
    repair_ buffer
    if not is_valid_ buffer:
      // TODO(kasper): Should we delete the whole thing here? It is
      // slow but it is potentially a way out of jail.
      dump_ buffer
      throw "INVALID_STATE"
    return true

  is_valid_ buffer/ByteArray -> bool:
    result := false
    elapsed := Duration.of: result = is_valid_x_ buffer
    print_ "[validating took $elapsed]"
    return result

  is_valid_x_ buffer/ByteArray -> bool:
    if not (0 <= read_page_ < size_ and 0 <= write_page_ < size_): return false
    if (round_down read_page_ size_per_page_) != read_page_: return false
    if (round_down write_page_ size_per_page_) != write_page_: return false

    // Handle split RW pages.
    if read_page_ != write_page_:
      read_sn := null

      while true:
        is_committed_page_ read_page_ buffer: | sn is_acked count |
          // If the read page is already ack'ed, we should have moved
          // the read page forward.
          if is_acked: return false
          previous := read_page_ - size_per_page_
          if previous < 0: previous += size_
          is_committed_page_ previous buffer: | snx is_acked count |
            if not is_acked:
              // If the previous page is earlier in the page list than
              // the read page (common case), we insist that the SN
              // of the previous page should be strictly smaller than
              // the SN of the read page. Otherwise, repairing will
              // make the read page go back. If the previous page is
              // actually after the read page due to wrap around, then
              // repairing will not push the read page forward if the
              // SNs are equal, so we allow that.
              compare := (previous < read_page_) ? 0 : -1
              // TODO(kasper): Try to get rid of the write page check.
              if previous != write_page_ and (api.ArtemisService.channel_position_compare sn snx) <= compare:
                return false
              if sn == (SN.next snx --increment=count): return false
          read_sn = sn
          break
        return false

      is_committed_page_ write_page_ buffer: | sn is_acked count |
        if (api.ArtemisService.channel_position_compare read_sn sn) >= 0: return false
        offset := repair_find_write_offset_ buffer write_page_
        if not offset: return false
        next := write_page_ + size_per_page_
        write_offset_ = next  // Don't allow appending to committed pages.
        if next >= size_: next = 0
        is_committed_page_ next buffer: | snx |
          // If count is zero, we really shouldn't have committed the
          // next page so something is wrong. Also, if the SN of the
          // next page is higher than that of the write page then
          // repairing would pick that.

          // If the next page is later in the page list than the
          // write page (common case), we allow it to have the
          // same SN as the write page. Repairing will ignore
          // such a page. If the next page is earlier due to wrap
          // around, we insist that the write page has a higher
          // SN. If it hasn't, repairing would move the write page
          // forward to the next page.
          compare := (next > write_page_) ? -1 : 0
          if count == 0 or (api.ArtemisService.channel_position_compare sn snx) <= compare:
            return false
          return true
        is_uncommitted_page_ next buffer: | snx |
          if snx == (SN.next sn --increment=count): return false
          return true
        return true

      is_uncommitted_page_ write_page_ buffer: | sn |
        if (api.ArtemisService.channel_position_compare read_sn sn) >= 0:
          return false
        offset := repair_find_write_offset_ buffer write_page_
        if not offset: return false
        write_offset_ = offset  // Potentially repaired.
        previous := write_page_ - size_per_page_
        if previous < 0: previous += size_
        is_committed_page_ previous buffer: | snx is_acked count |
          if sn != (SN.next snx --increment=count): return false
          return true
        return false

      // Write page is invalid; neither committed nor uncommitted.
      return false

    // Handle joined RW pages.
    is_committed_page_ read_page_ buffer: | sn is_acked count |
      // If the read page is already ack'ed, we should have moved
      // the read page forward.
      if is_acked: return false
      offset := repair_find_write_offset_ buffer read_page_
      if not offset: return false
      next := read_page_ + size_per_page_
      write_offset_ = next  // Don't allow appending to committed pages.
      assert: count > 0

      previous := read_page_ - size_per_page_
      if previous < 0: previous += size_
      is_committed_page_ previous buffer: | snx is_acked count |
        if not is_acked:
          compare := (previous < read_page_) ? 0 : -1
          if (api.ArtemisService.channel_position_compare sn snx) <= compare: return false
          if sn == (SN.next snx --increment=count): return false

      if next >= size_: next = 0
      is_committed_page_ next buffer: | snx |
        compare := (next > write_page_) ? -1 : 0
        if (api.ArtemisService.channel_position_compare sn snx) <= compare: return false
        return true
      is_uncommitted_page_ next buffer: | snx |
        if snx == (SN.next sn --increment=count): return false
        return true
      return true

    is_uncommitted_page_ read_page_ buffer: | sn |
      offset := repair_find_write_offset_ buffer read_page_
      if not offset: return false
      write_offset_ = offset  // Potentially repaired.
      previous := read_page_ - size_per_page_
      if previous < 0: previous += size_
      is_committed_page_ previous buffer: | snx is_acked count |
        if not is_acked: return false
        if sn != (SN.next snx --increment=count): return false
        return true
      return false

    return false

  repair_ buffer/ByteArray -> none:
    elapsed := Duration.of: repair_x_ buffer
    print_ "[repairing took $elapsed]"

  repair_x_ buffer/ByteArray -> none:
    last_page/int? := null
    last_sn/int := -1
    last_is_acked/bool := false
    last_count/int := -1

    for page := 0; page < size_; page += size_per_page_:
      is_committed_page_ page buffer: | sn is_acked count |
        if not last_page or (api.ArtemisService.channel_position_compare sn last_sn) > 0:
          last_page = page
          last_sn = sn
          last_is_acked = is_acked
          last_count = count

    if not last_page:
      // Couldn't find a page. Start from scratch with
      // a brand new sequence number.
      repair_reset_ buffer SN.new
      return

    first_page := last_page
    first_sn := last_sn
    if not last_is_acked:
      page := last_page
      while true:
        page = page - size_per_page_
        if page < 0: page += size_
        is_committed_page_ page buffer: | sn is_acked count |
          if not is_acked and (SN.next sn --increment=count) == first_sn:
            // We should not be able to get to a point where all pages
            // are non-ack'ed (count > 0) and chained together with correct
            // sequence numbers. It requires that the total number
            // of pages times the maximum count per page exceeds the
            // maximum sequence number.
            assert: count > 0
            if page == last_page:
              // This shouldn't happen but we're being careful to avoid
              // running in an infinite loop.
              repair_reset_ buffer SN.new
              return
            first_sn = sn
            first_page = page
            continue
        // Found page that isn't a committed prefix to the
        // already discovered committed range.
        break

    read_page_ = first_page
    write_page_ = last_page
    prevalidated_ = 0

    next_sn := SN.next last_sn --increment=last_count
    next := last_page + size_per_page_
    if next >= size_: next = 0

    if next != first_page:  // Don't check the first page again.
      is_uncommitted_page_ next buffer: | sn |
        if sn == next_sn:
          offset := repair_find_write_offset_ buffer next
          if offset:
            write_page_ = next
            write_offset_ = offset
          else:
            // The uncommitted page after the current write
            // page is invalid. We need to construct a new
            // one to make sure it is valid after repairing.
            advance_write_page_ buffer sn

    // If the write page remains the last committed page, we
    // check to see if that has valid encoded entries.
    if write_page_ == last_page:
      write_offset_ = next  // Don't allow appending to committed pages.
      region_.read --from=write_page_ buffer
      if not repair_find_write_offset_ buffer write_page_:
        // Found a committed, but incorrect write page. This
        // is a pretty serious matter, so we reset everything
        // but start from the next sequence number.
        repair_reset_ buffer next_sn
        return

    // If the last page is already acknowledged, we need to
    // ensure that we move the read page forward. This may
    // also move the write page forward if the write page
    // happens to be the last committed page.
    if last_is_acked: advance_read_page_ buffer next_sn

  repair_find_write_offset_ buffer/ByteArray page/int -> int?:
    region_.read --from=page buffer
    cursor := HEADER_SIZE_
    if (buffer[cursor] & 0x80) == 0:
      // Page content must start with MSB set.
      return null
    while cursor < size_per_page_:
      if buffer[cursor] == 0xff:
        for i := cursor + 1; i < size_per_page_; i++:
          if buffer[i] != 0xff:
            // Page must have all trailing bits set.
            return null
        return page + cursor
      cursor++
    return page + cursor

  repair_reset_ buffer/ByteArray initial_sn/int -> none:
    // Start from scratch by building up a committed and ack'ed
    // page as the last one.
    read_page_ = size_ - size_per_page_
    write_page_ = size_ - size_per_page_
    region_.erase --from=write_page_ --to=write_page_ + size_per_page_

    buffer.fill 0xff
    LITTLE_ENDIAN.put_uint32 buffer HEADER_MARKER_OFFSET_ MARKER_
    LITTLE_ENDIAN.put_uint32 buffer HEADER_SN_OFFSET_ initial_sn
    LITTLE_ENDIAN.put_uint16 buffer HEADER_COUNT_OFFSET_ 0xffff
    LITTLE_ENDIAN.put_uint32 buffer HEADER_CHECKSUM_OFFSET_ 0xffff_ffff
    crc32 := crc.Crc32
    crc32.add buffer
    LITTLE_ENDIAN.put_uint16 buffer HEADER_COUNT_OFFSET_ 0
    LITTLE_ENDIAN.put_uint32 buffer HEADER_CHECKSUM_OFFSET_ crc32.get_as_int
    region_.write --from=write_page_ buffer[..HEADER_SIZE_]
    write_offset_ = write_page_ + HEADER_SIZE_
    advance_read_page_ buffer initial_sn

  is_committed_page_ page/int buffer/ByteArray [found] -> none:
    region_.read --from=page buffer
    marker := LITTLE_ENDIAN.uint32 buffer HEADER_MARKER_OFFSET_
    if marker != MARKER_: return
    sn := LITTLE_ENDIAN.uint32 buffer HEADER_SN_OFFSET_
    if not (SN.is_valid sn): return
    expected_checksum := LITTLE_ENDIAN.uint32 buffer HEADER_CHECKSUM_OFFSET_
    expected_count := LITTLE_ENDIAN.uint16 buffer HEADER_COUNT_OFFSET_
    if not (0 <= expected_count <= size_per_page_ - HEADER_SIZE_): return
    actual_count := decode_count_all_ buffer
    if expected_count > 0 and actual_count != expected_count: return
    actual_crc32 := crc.Crc32
    // TODO(kasper): Should these be different values?
    LITTLE_ENDIAN.put_uint16 buffer HEADER_COUNT_OFFSET_ 0xffff
    LITTLE_ENDIAN.put_uint32 buffer HEADER_CHECKSUM_OFFSET_ 0xffff_ffff
    actual_crc32.add buffer
    if actual_crc32.get_as_int != expected_checksum:
      print "[checksum: expected $expected_checksum, but was $actual_crc32.get_as_int]"
      return
    found.call sn (expected_count == 0) actual_count

  is_uncommitted_page_ page/int buffer/ByteArray [found] -> none:
    region_.read --from=page buffer[..HEADER_SIZE_]
    marker := LITTLE_ENDIAN.uint32 buffer HEADER_MARKER_OFFSET_
    if marker != MARKER_: return
    if (buffer[HEADER_CHECKSUM_OFFSET_..HEADER_SIZE_].any: it != 0xff): return
    sn := LITTLE_ENDIAN.uint32 buffer HEADER_SN_OFFSET_
    found.call sn

  dump_ buffer/ByteArray -> none:
    for page := 0; page < size_; page += size_per_page_:
      banner := ?
      if page == read_page_ and page == write_page_:
        banner = "RW"
      else if page == write_page_:
        banner = " W"
      else if page == read_page_:
        banner = "R "
      else:
        banner = "  "

      is_committed_page_ page buffer: | sn is_acked count |
        if is_acked:
          print "- page $(%06x page):   committed $banner (sn=$(%08x sn), count=$(%04d count)) | ack'ed"
        else:
          print "- page $(%06x page):   committed $banner (sn=$(%08x sn), count=$(%04d count))"
        continue
      is_uncommitted_page_ page buffer: | sn |
        count := 0
        region_.read --from=page buffer
        decode_all_ buffer page: count++
        print "- page $(%06x page): uncommitted $banner (sn=$(%08x sn), count=$(%04d count))"
        continue
      print "- page $(%06x page): ########### $banner (sn=$("?" * 8), count=$("?" * 4))"

// TODO(kasper): Remove this helper.
untested_ value/bool message/string?=null -> bool:
  message = message ? " ($message)" : ""
  catch --trace: throw "untested$message"
  return value

// TODO(kasper): Remove this helper.
unimplemented_ message/string?=null -> none:
  untested_ false message
  throw "UNIMPLEMENTED"

class SN:
  static MASK ::= api.ArtemisService.CHANNEL_POSITION_MASK

  static is_valid sn/int -> bool:
    return sn == (sn & MASK)

  static next sn/int --increment/int=1 -> int:
    assert: increment >= 0
    result := (sn + increment) & MASK
    assert: (api.ArtemisService.channel_position_compare result sn) == (increment == 0 ? 0 : 1)
    return result

  static previous sn/int -> int:
    result := (sn - 1) & MASK
    assert: (api.ArtemisService.channel_position_compare result sn) == -1
    return result

  static compare sn1/int sn2/int -> int:
    return api.ArtemisService.channel_position_compare sn1 sn2

  static new -> int:
    return random MASK + 1
