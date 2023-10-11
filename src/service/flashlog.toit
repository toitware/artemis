// Copyright (C) 2023 Toitware ApS. All rights reserved.

import binary show LITTLE-ENDIAN
import crypto.crc
import system.storage

import artemis-pkg.api

class FlashLog:
  static HEADER-MARKER-OFFSET_   ::= 0
  static HEADER-SN-OFFSET_       ::= 4 + HEADER-MARKER-OFFSET_
  static HEADER-CHECKSUM-OFFSET_ ::= 4 + HEADER-SN-OFFSET_
  static HEADER-COUNT-OFFSET_    ::= 4 + HEADER-CHECKSUM-OFFSET_
  static HEADER-SIZE_            ::= 2 + HEADER-COUNT-OFFSET_

  static MARKER_ ::= 0x21_CE_A9_66

  region_/storage.Region
  capacity/int
  capacity-per-page_/int

  // One page buffer. Re-used whenever possible.
  buffer_/ByteArray? := ?

  // Cursors for read and write.
  read-page_/int := -1
  write-page_/int := -1
  write-offset_/int := -1

  // We keep track of the length of the sequence
  // of already validated pages that follow the
  // read page. We look at those pages when we
  // peek ahead, so we want to avoid redoing the
  // validation over and over again.
  read-page-validated_/int := 0

  // TODO(kasper): This should be cleaned up. It might make sense
  // to combine the FlashLog and the ChannelResource more somehow.
  usage_/int := 0

  constructor region/storage.Region:
    if not region.write-can-clear-bits:
      throw "Must be able to clear bits"
    if region.erase-value != 0xff:
      throw "Must erase to all set bits"
    if region.size <= region.erase-granularity:
      throw "Must have space for two pages"
    region_ = region
    capacity = region.size
    capacity-per-page_ = region.erase-granularity
    buffer_ = ByteArray capacity-per-page_
    with-buffer_: ensure-valid_ it

  size -> int:
    committed := write-page_ - read-page_
    if committed < 0: committed += capacity
    return committed + (write-offset_ - write-page_)

  acquire -> int:
    return ++usage_

  release -> int:
    usage := usage_ - 1
    usage_ = usage
    if usage == 0: region_.close
    return usage

  append bytes/ByteArray -> none:
    append bytes --if-full=: throw "OUT_OF_BOUNDS"

  append bytes/ByteArray [--if-full] -> none:
    // We compute the size by counting the number of bits we need.
    // The first byte is special since it only encodes 6 bits, so
    // we pull that out of the computation (add 1), so we end up
    // with something like (bits - 6) / 7. Since we want to do a
    // ceiling division by 7, we get (bits - 6 + 7 - 1) / 7 and
    // end up with the nicer looking:
    size := 1 + (bytes.size << 3) / 7
    if size > capacity-per-page_ - HEADER-SIZE_: throw "Bad Argument"

    with-buffer_ --if-absent=(: ByteArray size): | buffer/ByteArray |
      // Check to see if we have to advance the write page.
      next := write-page_ + capacity-per-page_
      if write-offset_ + size > next:
        if next >= capacity: next = 0

        // It is rather unfortunate that we have to reallocate the
        // buffer here if it isn't big enough. This happens when
        // we need to advance the write page while we're still busy
        // reading another page.
        if buffer.size < capacity-per-page_: buffer = ByteArray capacity-per-page_

        // Read the whole page, so we can get the sequence
        // number and the count. If the page isn't committed
        // we will need to decode all entries to compute the
        // correct sequence number for the next write page.
        region_.read --from=write-page_ buffer
        sn := LITTLE-ENDIAN.uint32 buffer HEADER-SN-OFFSET_
        count := LITTLE-ENDIAN.uint16 buffer HEADER-COUNT-OFFSET_

        // Commit if necessary and compute the next sequence number.
        if count == 0xffff: count = commit-if-non-empty_ buffer write-page_
        next-sn := SN.next sn --increment=count

        // Advance the write page.
        if not advance-write-page_ buffer next-sn:
          if-full.call
          return
        assert: is-valid_ buffer

      encoded-size := encode-next_ buffer bytes
      assert: size == encoded-size
      region_.write --from=write-offset_ buffer[..size]
      write-offset_ += size

  /**
  Reads the page $peek pages after the read page
    into the given buffer.

  Returns a list with the following elements:
    [0]: page first sequence number  / int
    [1]: page start cursor           / int?
    [2]: page element count          / int
    [3]: page buffer                 / ByteArray
  */
  read-page buffer/ByteArray --peek/int=0 -> List:
    if peek < 0 or buffer.size != capacity-per-page_:
      throw "Bad Argument"
    prevalidated := read-page-validated_
    // Run through the pages and skip or validate the ones
    // that come before the page we're interested in.
    page := read-page_
    next-sn := null
    peek.repeat: | index/int |
      // If we reach the write page while running through
      // the pages we're not interested in, we're done.
      if page == write-page_:
        region_.read --from=page buffer[..HEADER-SIZE_]
        sn := LITTLE-ENDIAN.uint32 buffer HEADER-SN-OFFSET_
        return [sn, null, 0, buffer]
      current := page
      page += capacity-per-page_
      if page >= capacity: page = 0
      if index >= prevalidated:
        is-committed-page_ current buffer: | sn is-acked count |
          if index == prevalidated or sn == next-sn:
            next-sn = SN.next sn --increment=count
            continue.repeat
        // Found uncommitted or wrong page. This shouldn't
        // happen so we reset and tell the user that something
        // was terribly wrong.
        repair-reset_ buffer SN.new
        throw "INVALID_STATE"
    read-page-validated_ = max peek prevalidated
    commit-and-read_ buffer page: | sn count |
      cursor := count == 0 ? null : HEADER-SIZE_
      return [sn, cursor, count, buffer]
    unreachable

  acknowledge sn/int -> none:
    with-buffer_: | buffer/ByteArray |
      is-committed-page_ read-page_ buffer: | sn_ is-acked count |
        next-sn := SN.next sn_ --increment=count
        last-sn := SN.previous next-sn
        if sn != last-sn: throw "Bad Argument"

        // Set the count to zero to mark this as acknowledged.
        if not is-acked:
          region_.write --from=(read-page_ + HEADER-COUNT-OFFSET_) #[0, 0]

        advance-read-page_ buffer next-sn
        read-page-validated_ = max 0 (read-page-validated_ - 1)
        assert: is-valid_ buffer
        return
    throw "Cannot acknowledge unread page"

  // ------------------------------------------------------------------------

  with-buffer_ [block] -> any:
    return with-buffer_ block --if-absent=: throw "INVALID_STATE"

  with-buffer_ [block] [--if-absent] -> any:
    original := buffer_
    buffer_ = null
    try:
      buffer := original or if-absent.call
      return block.call buffer
    finally:
      if original: buffer_ = original

  /**
  Calls the $block with the first sequence number in the
    page and the element count.
  */
  commit-and-read_ buffer/ByteArray page/int [block] -> none:
    // TODO(kasper): Handle reading from ack'ed pages. We
    // have an invariant that makes it impossible to get
    // to this point, but we should handle it gracefully.

    // TODO(kasper): We shouldn't be allowed to read
    // beyond the write page. Can we check that here
    // or do we need to do it outside?

    region_.read --from=page buffer
    sn := LITTLE-ENDIAN.uint32 buffer HEADER-SN-OFFSET_
    count := LITTLE-ENDIAN.uint16 buffer HEADER-COUNT-OFFSET_
    if count != 0xffff:
      // Already committed. We're done.
      block.call sn count
      return

    count = commit-if-non-empty_ buffer page
    if count > 0 and page == write-page_:
      // If we've committed the current write page,
      // we set the write offset at the end of the
      // page, so the next append will cause us to
      // advance the write page.
      write-offset_ = write-page_ + capacity-per-page_
    block.call sn count

  advance-read-page_ buffer/ByteArray sn/int -> none:
    // Don't go beyond the write page. We have at
    // least two pages, so advancing the write page
    // will succeed.
    if read-page_ == write-page_:
      advance-write-page_ buffer sn
      read-page_ = write-page_
      return

    read-page_ += capacity-per-page_
    if read-page_ >= capacity: read-page_ = 0

    is-committed-page_ read-page_ buffer: | snx is-acked count |
      if is-acked or snx != sn: repair_ buffer
      return
    is-uncommitted-page_ read-page_ buffer: | snx |
      if snx != sn: repair_ buffer
      return
    repair_ buffer

  advance-write-page_ buffer/ByteArray sn/int -> bool:
    next := write-page_ + capacity-per-page_
    if next >= capacity: next = 0

    // Don't go into the read page.
    if next == read-page_: return false

    // Clear the page and start writing into it!
    region_.erase --from=next --to=next + capacity-per-page_
    assert: HEADER-MARKER-OFFSET_ == 0 and HEADER-SN-OFFSET_ == 4
    LITTLE-ENDIAN.put-uint32 buffer HEADER-MARKER-OFFSET_ MARKER_
    LITTLE-ENDIAN.put-uint32 buffer HEADER-SN-OFFSET_ sn
    region_.write --from=(next + HEADER-MARKER-OFFSET_) buffer[.. HEADER-SN-OFFSET_ + 4]
    write-page_ = next
    write-offset_ = next + HEADER-SIZE_
    return true

  commit-if-non-empty_ buffer/ByteArray page/int -> int:
    count := decode-count_ buffer
    if count == 0: return 0
    assert: (LITTLE-ENDIAN.uint32 buffer HEADER-CHECKSUM-OFFSET_) == 0xffff_ffff
    assert: (LITTLE-ENDIAN.uint16 buffer HEADER-COUNT-OFFSET_) == 0xffff
    crc32 := crc.Crc32
    crc32.add buffer
    // Write the count and checksum together.
    assert: HEADER-COUNT-OFFSET_ == HEADER-CHECKSUM-OFFSET_ + 4
    assert: HEADER-SIZE_ == HEADER-COUNT-OFFSET_ + 2
    LITTLE-ENDIAN.put-uint32 buffer HEADER-CHECKSUM-OFFSET_ crc32.get-as-int
    LITTLE-ENDIAN.put-uint16 buffer HEADER-COUNT-OFFSET_ count
    region_.write
        --from=(page + HEADER-CHECKSUM-OFFSET_)
        buffer[HEADER-CHECKSUM-OFFSET_..HEADER-SIZE_]
    return count

  decode-count_ buffer/ByteArray -> int:
    count := 0
    cursor := HEADER-SIZE_
    while true:
      next := buffer[cursor++]
      if next & 0x80 != 0:
        if next == 0xff:
          return count
        else:
          count++
      if cursor == buffer.size:
        return count

  encode-next_ buffer/ByteArray bytes/ByteArray -> int:
    assert: not bytes.is-empty
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

  ensure-valid_ buffer/ByteArray -> bool:
    if is-valid_ buffer: return false
    repair_ buffer
    if not is-valid_ buffer:
      // TODO(kasper): Should we delete the whole thing here? It is
      // slow but it is potentially a way out of jail.
      throw "INVALID_STATE"
    return true

  is-valid_ buffer/ByteArray -> bool:
    if not (0 <= read-page_ < capacity and 0 <= write-page_ < capacity): return false
    if (round-down read-page_ capacity-per-page_) != read-page_: return false
    if (round-down write-page_ capacity-per-page_) != write-page_: return false

    // Handle split RW pages.
    if read-page_ != write-page_:
      read-sn := null

      while true:
        is-committed-page_ read-page_ buffer: | sn is-acked count |
          // If the read page is already ack'ed, we should have moved
          // the read page forward.
          if is-acked: return false
          previous := read-page_ - capacity-per-page_
          if previous < 0: previous += capacity
          is-committed-page_ previous buffer: | snx is-acked count |
            if not is-acked:
              // If the previous page is earlier in the page list than
              // the read page (common case), we insist that the SN
              // of the previous page should be strictly smaller than
              // the SN of the read page. Otherwise, repairing will
              // make the read page go back. If the previous page is
              // actually after the read page due to wrap around, then
              // repairing will not push the read page forward if the
              // SNs are equal, so we allow that.
              compare := (previous < read-page_) ? 0 : -1
              // TODO(kasper): Try to get rid of the write page check.
              if previous != write-page_ and (api.ArtemisService.channel-position-compare sn snx) <= compare:
                return false
              if sn == (SN.next snx --increment=count): return false
          read-sn = sn
          break
        return false

      is-committed-page_ write-page_ buffer: | sn is-acked count |
        if (api.ArtemisService.channel-position-compare read-sn sn) >= 0: return false
        offset := repair-find-write-offset_ buffer write-page_
        if not offset: return false
        next := write-page_ + capacity-per-page_
        write-offset_ = next  // Don't allow appending to committed pages.
        if next >= capacity: next = 0
        is-committed-page_ next buffer: | snx |
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
          compare := (next > write-page_) ? -1 : 0
          if count == 0 or (api.ArtemisService.channel-position-compare sn snx) <= compare:
            return false
          return true
        is-uncommitted-page_ next buffer: | snx |
          if snx == (SN.next sn --increment=count): return false
          return true
        return true

      is-uncommitted-page_ write-page_ buffer: | sn |
        if (api.ArtemisService.channel-position-compare read-sn sn) >= 0:
          return false
        offset := repair-find-write-offset_ buffer write-page_
        if not offset: return false
        write-offset_ = offset  // Potentially repaired.
        previous := write-page_ - capacity-per-page_
        if previous < 0: previous += capacity
        is-committed-page_ previous buffer: | snx is-acked count |
          if sn != (SN.next snx --increment=count): return false
          return true
        return false

      // Write page is invalid; neither committed nor uncommitted.
      return false

    // Handle joined RW pages.
    is-committed-page_ read-page_ buffer: | sn is-acked count |
      // If the read page is already ack'ed, we should have moved
      // the read page forward.
      if is-acked: return false
      offset := repair-find-write-offset_ buffer read-page_
      if not offset: return false
      next := read-page_ + capacity-per-page_
      write-offset_ = next  // Don't allow appending to committed pages.
      assert: count > 0

      previous := read-page_ - capacity-per-page_
      if previous < 0: previous += capacity
      is-committed-page_ previous buffer: | snx is-acked count |
        if not is-acked:
          compare := (previous < read-page_) ? 0 : -1
          if (api.ArtemisService.channel-position-compare sn snx) <= compare: return false
          if sn == (SN.next snx --increment=count): return false

      if next >= capacity: next = 0
      is-committed-page_ next buffer: | snx |
        compare := (next > write-page_) ? -1 : 0
        if (api.ArtemisService.channel-position-compare sn snx) <= compare: return false
        return true
      is-uncommitted-page_ next buffer: | snx |
        if snx == (SN.next sn --increment=count): return false
        return true
      return true

    is-uncommitted-page_ read-page_ buffer: | sn |
      offset := repair-find-write-offset_ buffer read-page_
      if not offset: return false
      write-offset_ = offset  // Potentially repaired.
      previous := read-page_ - capacity-per-page_
      if previous < 0: previous += capacity
      is-committed-page_ previous buffer: | snx is-acked count |
        if not is-acked: return false
        if sn != (SN.next snx --increment=count): return false
        return true
      return false

    return false

  repair_ buffer/ByteArray -> none:
    last-page/int? := null
    last-sn/int := -1
    last-is-acked/bool := false
    last-count/int := -1

    for page := 0; page < capacity; page += capacity-per-page_:
      is-committed-page_ page buffer: | sn is-acked count |
        if not last-page or (api.ArtemisService.channel-position-compare sn last-sn) > 0:
          last-page = page
          last-sn = sn
          last-is-acked = is-acked
          last-count = count

    if not last-page:
      // Couldn't find a page. Start from scratch with
      // a brand new sequence number.
      repair-reset_ buffer SN.new
      return

    first-page := last-page
    first-sn := last-sn
    if not last-is-acked:
      page := last-page
      while true:
        page = page - capacity-per-page_
        if page < 0: page += capacity
        is-committed-page_ page buffer: | sn is-acked count |
          if not is-acked and (SN.next sn --increment=count) == first-sn:
            // We should not be able to get to a point where all pages
            // are non-ack'ed (count > 0) and chained together with correct
            // sequence numbers. It requires that the total number
            // of pages times the maximum count per page exceeds the
            // maximum sequence number.
            assert: count > 0
            if page == last-page:
              // This shouldn't happen but we're being careful to avoid
              // running in an infinite loop.
              repair-reset_ buffer SN.new
              return
            first-sn = sn
            first-page = page
            continue
        // Found page that isn't a committed prefix to the
        // already discovered committed range.
        break

    read-page_ = first-page
    write-page_ = last-page
    read-page-validated_ = 0

    next-sn := SN.next last-sn --increment=last-count
    next := last-page + capacity-per-page_
    if next >= capacity: next = 0

    if next != first-page:  // Don't check the first page again.
      is-uncommitted-page_ next buffer: | sn |
        if sn == next-sn:
          offset := repair-find-write-offset_ buffer next
          if offset:
            write-page_ = next
            write-offset_ = offset
          else:
            // The uncommitted page after the current write
            // page is invalid. We need to construct a new
            // one to make sure it is valid after repairing.
            // The uncommitted page cannot be the read page
            // so advancing the write page will succeed.
            advance-write-page_ buffer sn

    // If the write page remains the last committed page, we
    // check to see if that has valid encoded entries.
    if write-page_ == last-page:
      write-offset_ = next  // Don't allow appending to committed pages.
      region_.read --from=write-page_ buffer
      if not repair-find-write-offset_ buffer write-page_:
        // Found a committed, but incorrect write page. This
        // is a pretty serious matter, so we reset everything
        // but start from the next sequence number.
        repair-reset_ buffer next-sn
        return

    // If the last page is already acknowledged, we need to
    // ensure that we move the read page forward. This may
    // also move the write page forward if the write page
    // happens to be the last committed page.
    if last-is-acked: advance-read-page_ buffer next-sn

  repair-find-write-offset_ buffer/ByteArray page/int -> int?:
    region_.read --from=page buffer
    cursor := HEADER-SIZE_
    if (buffer[cursor] & 0x80) == 0:
      // Page content must start with MSB set.
      return null
    while cursor < capacity-per-page_:
      if buffer[cursor] == 0xff:
        for i := cursor + 1; i < capacity-per-page_; i++:
          if buffer[i] != 0xff:
            // Page must have all trailing bits set.
            return null
        return page + cursor
      cursor++
    return page + cursor

  repair-reset_ buffer/ByteArray initial-sn/int -> none:
    // Start from scratch by building up a committed and ack'ed
    // page as the last one.
    read-page_ = capacity - capacity-per-page_
    write-page_ = capacity - capacity-per-page_
    region_.erase --from=write-page_ --to=write-page_ + capacity-per-page_

    buffer.fill 0xff
    LITTLE-ENDIAN.put-uint32 buffer HEADER-MARKER-OFFSET_ MARKER_
    LITTLE-ENDIAN.put-uint32 buffer HEADER-SN-OFFSET_ initial-sn
    crc32 := crc.Crc32
    crc32.add buffer
    LITTLE-ENDIAN.put-uint32 buffer HEADER-CHECKSUM-OFFSET_ crc32.get-as-int
    LITTLE-ENDIAN.put-uint16 buffer HEADER-COUNT-OFFSET_ 0
    region_.write --from=write-page_ buffer[..HEADER-SIZE_]
    write-offset_ = write-page_ + HEADER-SIZE_
    advance-read-page_ buffer initial-sn

  is-committed-page_ page/int buffer/ByteArray [found] -> none:
    region_.read --from=page buffer
    marker := LITTLE-ENDIAN.uint32 buffer HEADER-MARKER-OFFSET_
    if marker != MARKER_: return
    // Validate sequence number.
    sn := LITTLE-ENDIAN.uint32 buffer HEADER-SN-OFFSET_
    if not (SN.is-valid sn): return
    // Validate count.
    expected-count := LITTLE-ENDIAN.uint16 buffer HEADER-COUNT-OFFSET_
    if not (0 <= expected-count <= capacity-per-page_ - HEADER-SIZE_): return
    actual-count := decode-count_ buffer
    if expected-count > 0 and actual-count != expected-count: return
    // Validate checksum.
    expected-checksum := LITTLE-ENDIAN.uint32 buffer HEADER-CHECKSUM-OFFSET_
    crc32 := crc.Crc32
    // The checksum is based on the page bytes when the count and
    // the checksum has not been filled in, so we reset those
    // before computing the checksum.
    buffer.fill 0xff --from=HEADER-CHECKSUM-OFFSET_ --to=HEADER-SIZE_
    crc32.add buffer
    actual-checksum := crc32.get-as-int
    if actual-checksum != expected-checksum: return
    // Invoke the block: | sn is_ack count |.
    found.call sn (expected-count == 0) actual-count

  is-uncommitted-page_ page/int buffer/ByteArray [found] -> none:
    region_.read --from=page buffer[..HEADER-SIZE_]
    marker := LITTLE-ENDIAN.uint32 buffer HEADER-MARKER-OFFSET_
    if marker != MARKER_: return
    if (buffer[HEADER-CHECKSUM-OFFSET_..HEADER-SIZE_].any: it != 0xff): return
    sn := LITTLE-ENDIAN.uint32 buffer HEADER-SN-OFFSET_
    found.call sn


class SN:
  static MASK ::= api.ArtemisService.CHANNEL-POSITION-MASK

  static is-valid sn/int -> bool:
    return sn == (sn & MASK)

  static next sn/int --increment/int=1 -> int:
    assert: increment >= 0
    result := (sn + increment) & MASK
    assert: (api.ArtemisService.channel-position-compare result sn) == (increment == 0 ? 0 : 1)
    return result

  static previous sn/int -> int:
    result := (sn - 1) & MASK
    assert: (api.ArtemisService.channel-position-compare result sn) == -1
    return result

  static compare sn1/int sn2/int -> int:
    return api.ArtemisService.channel-position-compare sn1 sn2

  static new -> int:
    return random MASK + 1
