// Copyright (C) 2023 Toitware ApS.

import artemis.service.flashlog show FlashLog SN

import binary show LITTLE-ENDIAN
import crypto.crc
import expect show *
import system.storage

main:
  cases := [
    :: test-empty,
    :: test-sn-compare,
    :: test-first-read,
    :: test-small,
    :: test-large-append,
    :: test-append-while-reading,
    :: test-illegal-operations-while-reading,
    :: test-continue,
    :: test-avoid-double-read,
    :: test-all-committed,
    :: test-fill-up,
    :: test-full,
    :: test-repeated,
    :: test-illegal-ack,
    :: test-randomized,

    :: test-read-page,

    :: test-valid-w-corrupt,

    :: test-valid-joined-rw-committed,
    :: test-valid-joined-rw-committed-page-ordering,
    :: test-valid-joined-rw-uncommitted,

    :: test-valid-split-invalid,
    :: test-valid-split-w-committed,
    :: test-valid-split-w-uncommitted,
    :: test-valid-split-w-page-ordering,
    :: test-valid-split-r-page-ordering,

    :: test-repair-none,
    :: test-repair-committed-first,
    :: test-repair-committed-range,
    :: test-repair-sequence,
    :: test-repair-committed-wrong-order,
    :: test-repair-corrupt-uncommitted-page,
    :: test-repair-full-uncommitted-page,
    :: test-repair-all-read,
    :: test-repair-sn-wraparound,
    :: test-repair-on-ack,

    :: test-invalid-page-start,
    :: test-invalid-write-offset,
  ]

  cases.do: | test/Lambda |
    try:
      test.call
    finally:
      TestFlashLog.close-all

test-empty:
  flashlog := TestFlashLog 2
  expect-not flashlog.has-more
  flashlog.read: expect false

  flashlog = TestFlashLog 3
  expect-not flashlog.has-more
  flashlog.read: expect false

test-sn-compare:
  expect-equals -1 (SN.compare 1 2)
  expect-equals  0 (SN.compare 2 2)
  expect-equals  1 (SN.compare 2 1)

  max := SN.MASK
  expect-equals  1 (SN.compare (SN.next max) max)
  expect-equals -1 (SN.compare max (SN.next max))
  expect-equals  0 (SN.compare (SN.previous 0) max)

test-first-read:
  flashlog := TestFlashLog 2
  flashlog.append #[1, 2, 3]
  expect flashlog.has-more

  called := false
  flashlog.read:
    expect-bytes-equal #[1, 2, 3] it
    called = true
  expect called

test-small:
  expect-throw "Must have space for two pages": TestFlashLog 1

  flashlog := TestFlashLog 2
  100.repeat:
    input := List 20: ByteArray (random 25) + 1: random 0x100
    validate-round-trip flashlog input
    expect-not flashlog.has-more

test-large-append:
  flashlog := TestFlashLog 2
  flashlog.append (ByteArray flashlog.max-entry-size)
  too-large := ByteArray flashlog.max-entry-size + 1
  expect-throw "Bad Argument": flashlog.append too-large

  // It is a bit nasty, but here we reach into the internals
  // of the FlashLog implementation to test that writing
  // more than the max entry size would indeed overflow.
  buffer := ByteArray flashlog.capacity-per-page_ + 1024
  written := (flashlog.encode-next_ buffer too-large)
  expect written > (flashlog.capacity-per-page_ - FlashLog.HEADER-SIZE_)

test-append-while-reading:
  flashlog := TestFlashLog 2
  input := [#[7, 9, 13], #[17, 19]]
  input.do: flashlog.append it

  last := null
  flashlog.read: | x sn |
    flashlog.append x
    last = sn
  flashlog.acknowledge last

  output := []
  flashlog.read: output.add it
  expect-list-equals input output

test-illegal-operations-while-reading:
  flashlog := TestFlashLog 2
  input := [#[7, 9, 13], #[17, 19]]
  input.do: flashlog.append it

  output := []
  last := null
  flashlog.read: | x sn |
    output.add x
    expect-throw "INVALID_STATE": flashlog.read: null
    expect-throw "INVALID_STATE": flashlog.has-more
    expect-throw "INVALID_STATE": flashlog.acknowledge sn
    last = sn
  flashlog.acknowledge last
  expect-list-equals input output
  expect-not flashlog.has-more

test-continue:
  flashlog := TestFlashLog 4
  flashlog.reset
  expect-not flashlog.has-more

  input := [
    #[1, 2, 3, 4],
    #[2, 3, 4],
    #[3, 4, 5, 6, 7],
  ]
  flashlog.append input[0]
  flashlog.append input[1]
  flashlog.reset
  expect flashlog.has-more
  flashlog.append input[2]
  count := 0

  flashlog.read:
    expect-bytes-equal input[count] it
    count++
  expect-equals 3 count

  flashlog.reset
  100.repeat:
    input.do: flashlog.append it
    if it % 21 == 0: flashlog.reset

  count = 0
  while flashlog.has-more:
    last := null
    flashlog.read: | _ sn |
      count++
      last = sn
    flashlog.acknowledge last
  expect-equals 3 + (input.size * 100) count

test-avoid-double-read:
  flashlog := TestFlashLog 2
  flashlog.append #[3, 4, 5, 6]
  flashlog.reset
  expect flashlog.has-more

  last := null
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last
  expect-not flashlog.has-more

  flashlog.reset
  expect-not flashlog.has-more

  flashlog.append #[1, 2, 3]
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last
  flashlog.append #[2, 3, 4]
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last
  expect-not flashlog.has-more

  flashlog.reset
  expect-not flashlog.has-more

test-all-committed:
  first := #[3, 4, 5, 6]
  second := #[2, 3, 4, 5]

  flashlog := TestFlashLog 2
  flashlog.append first
  flashlog.read: null  // Commit first page.

  last := null
  flashlog.append second
  flashlog.read: | x sn |
    expect-bytes-equal first x
    last = sn

  flashlog.acknowledge last
  flashlog.read: null  // Commit second page.

  flashlog.reset
  expect flashlog.has-more

  flashlog.read: | x sn |
    expect-bytes-equal second x
    last = sn
  flashlog.acknowledge last

test-fill-up:
  flashlog := TestFlashLog 2
  flashlog.append (ByteArray 1700)
  flashlog.append (ByteArray 1700)

  flashlog.append (ByteArray 1000)
  flashlog.append (ByteArray 1000)
  flashlog.append (ByteArray 1000)

  last := null
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last
  flashlog.reset

  count := 0
  flashlog.read: | _ sn | count++
  expect-equals 3 count

test-full:
  flashlog := TestFlashLog 2
  2.repeat:
    flashlog.append (ByteArray 1700)
    flashlog.append (ByteArray 1700)
  expect-throw "OUT_OF_BOUNDS": flashlog.append (ByteArray 1700)

test-repeated:
  flashlog := TestFlashLog 8
  20.repeat:
    // The worst case is that all the byte arrays are encoded as
    // 29 byte sequences, which means we only have room for 140
    // of them in each page. We need 8 pages for 1000 of those.
    input := List 1000: ByteArray (random 25) + 1: random 0x100
    validate-round-trip flashlog input
    expect-not flashlog.has-more

test-illegal-ack:
  flashlog := TestFlashLog 4
  expect-throw "Cannot acknowledge unread page": flashlog.acknowledge 0

  flashlog.append (ByteArray 100: random 100)
  expect-throw "Cannot acknowledge unread page": flashlog.acknowledge 0
  expect-equals 1 (read-all flashlog).size

  flashlog.append (ByteArray 100: random 100)
  expect-throw "Cannot acknowledge unread page": flashlog.acknowledge 0

  last := null
  flashlog.read: | _ sn | last = sn
  expect-throw "Bad Argument": flashlog.acknowledge -1
  expect-throw "Bad Argument": flashlog.acknowledge -100
  expect-throw "Bad Argument": flashlog.acknowledge last - 1
  expect-throw "Bad Argument": flashlog.acknowledge last - 100
  expect-throw "Bad Argument": flashlog.acknowledge last + 1
  expect-throw "Bad Argument": flashlog.acknowledge last + 100
  expect-throw "Bad Argument": flashlog.acknowledge last + 10000

  flashlog.acknowledge last
  expect-not flashlog.has-more

test-randomized:
  100.repeat:
    flashlog := TestFlashLog 8
    if flashlog.has-more:
      flashlog.dump
      expect false --message="Randomized flash logs should be empty"
    flashlog.close

test-read-page:
  test-read-page [0, 1, 2]
  test-read-page [2, 1, 0]
  test-read-page [1, 0, 2]
  test-read-page [1, 2, 0]
  test-read-page [0, 0, 2, 2, 1, 1, 0, 2]
  test-read-page [2, 0, 1, 2, 2, 0, 0, 2]
  10.repeat: test-read-page (List 10: random 3)

test-read-page peek-order/List:
  flashlog := TestFlashLog 8
  buffer := ByteArray 4096

  // Fill up three pages with two entries in each.
  bytes := ByteArray 1700
  6.repeat:
    bytes.fill it
    flashlog.append bytes

  // Try to peek too far. We should just get empty results back.
  [99, 4, 7, 3, 1000].do:
    list := flashlog.read-page buffer --peek=it
    expect-null list[1]      // Cursor.
    expect-equals 0 list[2]  // Count.

  test-peeked ::= : | buffer/ByteArray peek/int |
    first-sn := null
    n := 0
    flashlog.decode buffer: | x sn |
      expect-equals 1700 x.size
      expect (x.every: it == peek * 2 + n)
      if not first-sn: first-sn = sn
      n++
    first-sn

  // Peek in the specified order.
  peek-order.do: | peek/int |
    list := flashlog.read-page buffer --peek=peek
    sn := list[0]
    expect-equals 14 list[1]  // Cursor.
    expect-equals 2 list[2]   // Count.
    first-sn := test-peeked.call buffer peek
    expect-equals first-sn sn

  // Try to peek too far. We should just get empty results back.
  [99, 4, 7, 3, 1000].do:
    list := flashlog.read-page buffer --peek=it
    expect-null list[1]      // Cursor.
    expect-equals 0 list[2]  // Count.

  // Ack the pages one by one.
  for acked := 1; acked <= 3; acked++:
    list := flashlog.read-page buffer
    flashlog.acknowledge (SN.previous (SN.next list[0] --increment=list[2]))
    [99, 4, 7, 3 - acked, 1000].do:
      list = flashlog.read-page buffer --peek=it
      expect-null list[1]      // Cursor.
      expect-equals 0 list[2]  // Count.

    // Peek in the specified order again but
    // take the acks into account.
    peek-order.do: | peek/int |
      adjusted-peek := peek - acked
      if adjusted-peek < 0:
        expect-throw "Bad Argument": flashlog.read-page buffer --peek=adjusted-peek
      else:
        sn := (flashlog.read-page buffer --peek=adjusted-peek)[0]
        expect-not-null sn
        last-sn := test-peeked.call buffer peek
        expect-equals last-sn sn

test-valid-w-corrupt:
  // Corrupt write page (contains garbage at end).
  test-valid-w-corrupt #[0x80, 0x01, 0xff, 0x80]
  test-valid-w-corrupt #[0x80, 0x02, 0xff, 0xfe]
  test-valid-w-corrupt #[0x80, 0x03, 0xff, 0x80, 0x04]
  test-valid-w-corrupt #[0x80, 0x05, 0xff, 0xfe, 0x06]

test-valid-w-corrupt write-page-bytes/ByteArray:
  // Joined RW, uncommitted.
  flashlog-0 := TestFlashLog.construct --repair --read-page=4096 --write-page=4096 [
    { "sn": 4, "entries": [ #[9, 8, 7] ], "state": "acked" },
    { "sn": 5, "bytes": write-page-bytes, "state": "uncommitted" },
  ]
  expect-equals 4096 flashlog-0.read-page_
  expect-equals 4096 flashlog-0.write-page_
  flashlog-0.append #[1, 2, 3]
  expect-structural-equals
      [ #[1, 2, 3] ]
      read-all flashlog-0 --expected-first-sn=4 + 1

  // Joined RW, committed.
  flashlog-1 := TestFlashLog.construct --repair --read-page=0 --write-page=0 [
    { "sn": 5, "bytes": write-page-bytes },
    {:}
  ]
  expect-equals 0 flashlog-1.read-page_
  expect-equals 0 flashlog-1.write-page_
  expect-not flashlog-1.has-more  // Should have been reset.
  flashlog-1.append #[1, 2, 3]
  expect-structural-equals
      [ #[1, 2, 3] ]
      read-all flashlog-1 --expected-first-sn=5 + 1

  // Split RW, uncommitted.
  flashlog-2 := TestFlashLog.construct --repair --read-page=0 --write-page=4096 [
    { "sn": 9, "entries": [ #[1, 2], #[9] ] },
    { "sn": 11, "bytes": write-page-bytes, "state": "uncommitted" },
  ]
  expect-equals 0 flashlog-2.read-page_
  expect-equals 4096 flashlog-2.write-page_
  expect-structural-equals
      [ #[1, 2], #[9] ]
      read-all flashlog-2 --expected-first-sn=9

  // Split RW, committed.
  flashlog-3 := TestFlashLog.construct --repair --read-page=4096 --write-page=8192 [
    {:},
    { "sn": 7, "entries": [ #[1, 2] ]},
    { "sn": 8, "bytes": write-page-bytes },
  ]
  expect-equals 0 flashlog-3.read-page_   // Repaired by resetting.
  expect-equals 0 flashlog-3.write-page_  // Repaired by resetting.
  expect-not flashlog-3.has-more  // Should have been reset.
  flashlog-3.append #[7, 8, 9]
  expect-structural-equals
      [ #[7, 8, 9] ]
      read-all flashlog-3 --expected-first-sn=8 + 1

test-valid-joined-rw-committed:
  flashlog-0 := TestFlashLog.construct --repair --read-page=0 --write-page=0 [
    { "sn": 4, "entries": [ #[0] ]},  // Should be read page.
    { "sn": 5, "entries": [ #[1] ]},  // Should be write page.
    {:},
  ]
  expect-equals 0 flashlog-0.read-page_
  expect-equals 4096 flashlog-0.write-page_

  flashlog-1 := TestFlashLog.construct --no-repair --read-page=0 --write-page=0 [
    { "sn": 4, "entries": [ #[0] ]},
    { "sn": 0, "fill": 0xff, "state": "uncommitted" },  // Uncommitted, invalid.
    {:},
  ]
  expect-equals 0 flashlog-1.read-page_
  expect-equals 0 flashlog-1.write-page_

  flashlog-2 := TestFlashLog.construct --no-repair --read-page=0 --write-page=0 [
    { "sn": 4, "entries": [ #[0] ]},
    { "sn": 9, "fill": 0xff, "state": "uncommitted" },  // Uncommitted, invalid.
    {:},
  ]
  expect-equals 0 flashlog-2.read-page_
  expect-equals 0 flashlog-2.write-page_

test-valid-joined-rw-uncommitted:
  flashlog-0 := TestFlashLog.construct --repair --read-page=0 --write-page=0 [
    { "sn": 7, "fill": 0xff, "state": "uncommitted" },
    { "sn": 5, "entries": [ #[1] ], "state": "acked" },
  ]
  expect-equals 0 flashlog-0.read-page_
  expect-equals 0 flashlog-0.write-page_

  flashlog-1 := TestFlashLog.construct --repair --read-page=0 --write-page=0 [
    { "sn": 7, "fill": 0xff, "state": "uncommitted" },
    {:},
  ]
  expect-equals 0 flashlog-1.read-page_
  expect-equals 0 flashlog-1.write-page_

test-valid-joined-rw-committed-page-ordering:
  flashlog-0 := TestFlashLog.construct --no-repair --read-page=0 --write-page=0 [
    { "sn": 4, "entries": [ #[7, 9] ]},
    { "sn": 4, "entries": [ #[2, 3, 4] ]},
    {:},
  ]
  expect-equals 0 flashlog-0.read-page_
  expect-equals 0 flashlog-0.write-page_
  expect-structural-equals
      [ #[7, 9] ]  // Repairing would ignore the page following the read page.
      read-all flashlog-0

  flashlog-1 := TestFlashLog.construct --no-repair --read-page=0 --write-page=0 [
    { "sn": 4, "entries": [ #[2, 3, 4] ]},
    {:},
    { "sn": 4, "entries": [ #[7, 9] ]},
  ]
  expect-equals 0 flashlog-1.read-page_
  expect-equals 0 flashlog-1.write-page_
  expect-structural-equals
      [ #[2, 3, 4] ]  // Repairing drops the last page.
      read-all flashlog-1

  flashlog-2 := TestFlashLog.construct --repair --read-page=8192 --write-page=8192 [
    { "sn": 4, "entries": [ #[2, 3, 4] ]},
    {:},
    { "sn": 4, "entries": [ #[7, 9] ]},
  ]
  expect-equals 0 flashlog-2.read-page_
  expect-equals 0 flashlog-2.write-page_
  expect-structural-equals
      [ #[2, 3, 4] ]  // Repairing drops the last page.
      read-all flashlog-2

  flashlog-3 := TestFlashLog.construct --repair --read-page=4096 --write-page=4096 [
    { "sn": 4, "entries": [ #[7, 9] ]},
    { "sn": 4, "entries": [ #[2, 3, 4] ]},
    {:},
  ]
  expect-equals 0 flashlog-3.read-page_
  expect-equals 0 flashlog-3.write-page_
  expect-structural-equals
      [ #[7, 9] ]  // Repairing drops the last page.
      read-all flashlog-3

test-valid-split-invalid:
  flashlog-0 := TestFlashLog.construct --repair --read-page=0 --write-page=4096 [
    { "sn": 7, "fill": 0xff, "state": "uncommitted" },
    { "sn": 5, "entries": [ #[1] ], "state": "acked" },
  ]
  expect-equals 0 flashlog-0.read-page_
  expect-equals 0 flashlog-0.write-page_
  expect-equals 0 (read-all flashlog-0).size

  flashlog-1 := TestFlashLog.construct --repair --read-page=4096 --write-page=0 [
    { "sn": 7, "checksum": 0x1234 },
    { "sn": 5, "entries": [ #[7] ] },
  ]
  expect-equals 4096 flashlog-1.read-page_
  expect-equals 4096 flashlog-1.write-page_
  expect-equals 1 (read-all flashlog-1).size

  flashlog-2 := TestFlashLog.construct --repair --read-page=4096 --write-page=0 [
    { "sn": 7, "checksum": 0x1234 },
    { "sn": 5, "entries": [ #[7] ], "state": "acked" },
  ]
  expect-equals 0 flashlog-2.read-page_
  expect-equals 0 flashlog-2.write-page_
  expect-equals 0 (read-all flashlog-2).size

  flashlog-3 := TestFlashLog.construct --repair --read-page=4096 --write-page=0 [
    { "sn": 4, "entries": [ #[8] ] },
    { "sn": 5, "entries": [ #[7] ] },
    {:},
  ]
  expect-equals 0 flashlog-3.read-page_
  expect-equals 4096 flashlog-3.write-page_
  expect-equals 2 (read-all flashlog-3).size

  flashlog-4 := TestFlashLog.construct --repair --read-page=4096 --write-page=8192 [
    { "sn": 6, "entries": [ #[8] ] },
    { "sn": 5, "entries": [ #[7] ] },
    {:},
  ]
  expect-equals 0 flashlog-4.read-page_
  expect-equals 0 flashlog-4.write-page_
  expect-equals 1 (read-all flashlog-4).size

test-valid-split-w-committed:
  flashlog-0 := TestFlashLog.construct --no-repair --read-page=0 --write-page=4096 [
    { "sn": 5, "entries": [ #[1] ] },
    { "sn": 6, "entries": [ #[2] ] },
    { "sn": 9, "fill": 0xff, "state": "uncommitted" },
  ]
  expect-equals 0 flashlog-0.read-page_
  expect-equals 4096 flashlog-0.write-page_
  expect-equals 2 (read-all flashlog-0).size

  flashlog-1 := TestFlashLog.construct --repair --read-page=0 --write-page=4096 [
    { "sn": 5, "entries": [ #[1] ] },
    { "sn": 6, "entries": [ #[2] ] },
    { "sn": 7, "fill": 0xff, "state": "uncommitted" },
  ]
  expect-equals 0 flashlog-1.read-page_
  expect-equals 8192 flashlog-1.write-page_
  expect-equals 2 (read-all flashlog-1).size

  flashlog-2 := TestFlashLog.construct --repair --read-page=0 --write-page=4096 [
    { "sn": 5, "entries": [ #[1] ] },
    { "sn": 6, "entries": [ #[2], #[3] ] },
    { "sn": 8, "entries": [ #[4] ] },
    {:},
  ]
  expect-equals 0 flashlog-2.read-page_
  expect-equals 8192 flashlog-2.write-page_
  expect-equals 4 (read-all flashlog-2).size

  flashlog-3 := TestFlashLog.construct --repair --read-page=0 --write-page=8192 [
    { "sn": 5, "entries": [ #[1] ] },
    {:},
    { "sn": 2, "entries": [ #[2], #[3] ] },
    {:},
  ]
  expect-equals 0 flashlog-3.read-page_
  expect-equals 0 flashlog-3.write-page_
  expect-equals 1 (read-all flashlog-3).size

  flashlog-4 := TestFlashLog.construct --repair --read-page=0 --write-page=8192 [
    { "sn": 1, "entries": [ #[1] ] },
    {:},
    { "sn": 2, "entries": [ ] },
    { "sn": 2, "entries": [ #[2], #[3] ] },
    {:},
  ]
  // This is slightly weird. The repairing didn't pick page 8192 as
  // the new RW page, because it appears ack'ed due to the count
  // being zero.
  expect-equals 12288 flashlog-4.read-page_
  expect-equals 12288 flashlog-4.write-page_
  expect-equals 0 (read-all flashlog-4).size

test-valid-split-w-uncommitted:
  flashlog-0 := TestFlashLog.construct --repair --read-page=0 --write-page=4096 [
    { "sn": 5, "entries": [ #[1] ] },
    { "sn": 4, "entries": [ #[2] ], "state": "uncommitted" },
    {:}
  ]
  expect-equals 0 flashlog-0.read-page_
  expect-equals 0 flashlog-0.write-page_
  expect-equals 1 (read-all flashlog-0).size

  flashlog-1 := TestFlashLog.construct --repair --read-page=0 --write-page=8192 [
    { "sn": 3, "entries": [ #[1] ] },
    {:},
    { "sn": 4, "entries": [ #[2] ], "state": "uncommitted" },
    {:}
  ]
  expect-equals 0 flashlog-1.read-page_
  expect-equals 0 flashlog-1.write-page_
  expect-equals 1 (read-all flashlog-1).size

  flashlog-2 := TestFlashLog.construct --repair --read-page=0 --write-page=8192 [
    { "sn": 3, "entries": [ #[1] ] },
    { "sn": 7, "entries": [ #[3], #[4] ] },
    { "sn": 4, "entries": [ #[2] ], "state": "uncommitted" },
    {:}
  ]
  expect-equals 4096 flashlog-2.read-page_
  expect-equals 4096 flashlog-2.write-page_
  expect-equals 2 (read-all flashlog-2).size

test-valid-split-r-page-ordering:
  // The second entry with SN 5 is ignored when repairing
  // because of its position in the page list. We don't
  // insist on repairing in this case.
  flashlog-0 := TestFlashLog.construct --no-repair --read-page=0 --write-page=8192 [
    { "sn": 5, "entries": [ #[1] ] },
    {:},
    { "sn": 6, "entries": [ #[4], #[3] ] },
    { "sn": 5, "entries": [ #[2] ] },
  ]
  expect-equals 0 flashlog-0.read-page_
  expect-equals 8192 flashlog-0.write-page_
  expect-structural-equals
      [ #[1], #[4], #[3] ]  // Auto-repaired after first page.
      read-all flashlog-0

  flashlog-1 := TestFlashLog.construct --repair --read-page=4096 --write-page=12288 [
    { "sn": 5, "entries": [ #[2] ] },
    { "sn": 5, "entries": [ #[1] ] },
    {:},
    { "sn": 6, "entries": [ #[2], #[3] ] },
  ]
  expect-equals 12288 flashlog-1.read-page_
  expect-equals 12288 flashlog-1.write-page_
  expect-equals 2 (read-all flashlog-1).size

  flashlog-2 := TestFlashLog.construct --repair --read-page=4096 --write-page=16384 [
    { "sn": 5, "entries": [ #[2] ] },
    { "sn": 5, "entries": [ #[1] ] },
    {:},
    { "sn": 5, "entries": [ ] },
    { "sn": 5, "fill": 0xff, "state": "uncommitted" },
  ]
  expect-equals 0 flashlog-2.read-page_
  expect-equals 0 flashlog-2.write-page_
  expect-equals 1 (read-all flashlog-2).size

test-valid-split-w-page-ordering:
  flashlog-0 := TestFlashLog.construct --no-repair --read-page=12288 --write-page=0 [
    { "sn": 6, "entries": [ #[2] ] },
    { "sn": 6, "entries": [ #[1] ] },
    {:},
    { "sn": 4, "entries": [ #[4], #[3] ] },
  ]
  expect-equals 12288 flashlog-0.read-page_
  expect-equals 0 flashlog-0.write-page_
  expect-structural-equals
      [ #[4], #[3], #[2] ]  // Page following write page is ignored.
      read-all flashlog-0

  flashlog-1 := TestFlashLog.construct --repair --read-page=8192 --write-page=12288 [
    { "sn": 6, "entries": [ #[1] ] },
    {:},
    { "sn": 4, "entries": [ #[4], #[3] ] },
    { "sn": 6, "entries": [ #[2] ] },
  ]
  expect-equals 0 flashlog-1.read-page_
  expect-equals 0 flashlog-1.write-page_
  expect-structural-equals
      [ #[1] ]  // Repairing drops the pages after the first one.
      read-all flashlog-1

test-repair-none:
  flashlog := TestFlashLog.construct --no-repair [
    { "sn": 4, "fill": 0xff, "state": "uncommitted" },
    { "sn": 4, "entries": [], "state": "acked" },
  ]
  output := read-all flashlog
  expect-equals 0 output.size

test-repair-committed-first:
  test-repair-committed-first 2
  test-repair-committed-first 3
  test-repair-committed-first 4
  test-repair-committed-first 10

test-repair-committed-first pages/int:
  // Fill all pages.
  flashlog := TestFlashLog pages
  pages.repeat:
    flashlog.append (ByteArray 1700)
    flashlog.append (ByteArray 1700)

  // Acknowledge the first page.
  expect-equals 0 flashlog.read-page_
  last := null
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last

  // Append more data in the first page.
  flashlog.append (ByteArray 1700)
  // It takes the first write to realize that we need
  // to write into the first page.
  expect-equals 0 flashlog.write-page_
  flashlog.append (ByteArray 1700)

  // Make room in the second page by acknowleding it.
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last

  // Commit the first page by overflowing it with
  // a too big write.
  flashlog.append (ByteArray 1700)

  flashlog.reset

  count := 0
  while flashlog.has-more:
    last = null
    flashlog.read: | _ sn |
      last = sn
      count++
    flashlog.acknowledge last

  // One page has one entry and the others have two.
  expect-equals ((pages - 1) * 2 + 1) count

test-repair-committed-range:
  flashlog := TestFlashLog 3
  flashlog.append (ByteArray 1700)
  flashlog.append (ByteArray 1700)

  flashlog.append (ByteArray 1700)
  flashlog.append (ByteArray 1700)

  flashlog.append (ByteArray 1000)
  flashlog.append (ByteArray 1000)
  flashlog.append (ByteArray 1000)

  flashlog.reset

  count := 0
  while flashlog.has-more:
    last := null
    flashlog.read: | _ sn |
      last = sn
      count++
    flashlog.acknowledge last
  expect-equals 7 count

test-repair-sequence:
  input := [
    #[1, 2, 3],
    #[2, 3],
  ]

  flashlog-0 := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ input[0] ] },
    { "sn": 5, "entries": [ input[1] ] },
  ]
  validate-round-trip flashlog-0 input --no-append

  flashlog-1 := TestFlashLog.construct --repair [
    { "sn": 5, "entries": [ input[1] ] },
    { "sn": 4, "entries": [ input[0] ] },
  ]
  validate-round-trip flashlog-1 input --no-append

  flashlog-2 := TestFlashLog.construct --repair [
    { "sn": 5, "entries": [ input[1] ] },
    {:},
    { "sn": 4, "entries": [ input[0] ] },
  ]
  validate-round-trip flashlog-2 input --no-append

  flashlog-3 := TestFlashLog.construct --repair [
    {:},
    { "sn": 5, "entries": [ input[0] ] },
    { "sn": 4, "entries": [ #[0xab, 0xbc]] },
    {:},
  ]
  validate-round-trip flashlog-3 input[..1] --no-append

  flashlog-4 := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ #[0xab, 0xbc]] },
    {:},
    { "sn": 5, "entries": [ input[0] ] },
  ]
  validate-round-trip flashlog-4 input[..1] --no-append

test-repair-committed-wrong-order:
  test-repair-committed-wrong-order 0 0
  test-repair-committed-wrong-order 5 5
  test-repair-committed-wrong-order SN.MASK SN.MASK

  test-repair-committed-wrong-order 5 4
  test-repair-committed-wrong-order 5 2
  test-repair-committed-wrong-order 5 SN.MASK
  test-repair-committed-wrong-order SN.MASK (SN.MASK - 100)

test-repair-committed-wrong-order sn0/int sn1/int:
  expect (SN.compare sn0 sn1) >= 0

  flashlog-0 := TestFlashLog.construct --repair [
    // Ack'ed page, followed by a non-acked page with lower
    // sequence number.
    { "sn": sn0, "entries": [ #[7] ], "state": "acked" },
    { "sn": sn1, "entries": [ #[8] ] },
  ]
  output-0 := read-all flashlog-0
  expect-equals 0 output-0.size
  flashlog-0.append #[9]
  expect-structural-equals [#[9]] (read-all flashlog-0 --expected-first-sn=(SN.next sn0))

  flashlog-1 := TestFlashLog.construct --repair [
    // Ack'ed page, followed by another acked page with lower
    // sequence number.
    { "sn": sn0, "entries": [ #[7] ], "state": "acked" },
    { "sn": sn1, "entries": [ #[8] ], "state": "acked" },
  ]
  output-1 := read-all flashlog-1
  expect-equals 0 output-1.size
  flashlog-1.append #[23]
  expect-structural-equals [#[23]] (read-all flashlog-1 --expected-first-sn=(SN.next sn0))

test-repair-corrupt-uncommitted-page:
  input := [
    #[7, 9, 13],
    #[2, 3, 5, 7],
  ]

  flashlog-0 := TestFlashLog.construct --repair  [
    { "sn": 4, "entries": [ input[0] ] },
    // Uncommitted, corrupt page (first entry doesn't have the MSB set).
    { "sn": 5, "bytes": #[0], "state": "uncommitted" },
  ]
  flashlog-0.append input[1]
  validate-round-trip flashlog-0 input --no-append

  flashlog-1 := TestFlashLog.construct --repair  [
    // Uncommitted, corrupt page (first entry doesn't have the MSB set).
    { "sn": 5, "bytes": #[0], "state": "uncommitted" },
    { "sn": 4, "entries": [ input[0] ] },
  ]
  flashlog-1.append input[1]
  validate-round-trip flashlog-1 input --no-append

  flashlog-2 := TestFlashLog.construct --repair [
    // Uncommitted, corrupt page (first entry doesn't have the MSB set).
    { "sn": 5, "bytes": #[0], "state": "uncommitted" },
    {:},
    { "sn": 4, "entries": [ input[0] ] },
  ]
  flashlog-2.append input[1]
  validate-round-trip flashlog-2 input --no-append

  // We need to reset the log here. Otherwise, we will not repair
  // it because the validation will find that the uncommitted page
  // is corrupt and ignore it.
  flashlog-3 := TestFlashLog.construct --reset --repair [
    { "sn": 4, "entries": [ input[0] ] },
    // Uncommitted, corrupt page (count isn't cleared).
    { "sn": 5, "entries": [ input[1] ], "count": 0xfeff, "checksum": 0xffff_ffff },
  ]
  flashlog-3.append input[1]
  validate-round-trip flashlog-3 input --no-append

  // We need to reset the log here. Otherwise, we will not repair
  // it because the validation will find that the uncommitted page
  // is corrupt and ignore it.
  flashlog-4 := TestFlashLog.construct --reset --repair [
    { "sn": 4, "entries": [ input[0] ] },
    // Uncommitted, corrupt page (checksum isn't cleared).
    { "sn": 5, "entries": [ input[1] ], "count": 0xffff, "checksum": 0xffff_feff },
  ]
  flashlog-4.append input[1]
  validate-round-trip flashlog-4 input --no-append

  flashlog-5 := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ input[0] ] },
    // Uncommitted, corrupt page (contains garbage at end).
    { "sn": 5, "bytes": #[0x80, 0x00, 0xff, 0xfe], "state": "uncommitted" },
  ]
  flashlog-5.append input[1]
  validate-round-trip flashlog-5 input --no-append

test-repair-full-uncommitted-page:
  flashlog := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ #[7, 8] ] },
    // Uncommitted, full page.
    { "sn": 5, "bytes": #[0x80], "fill": random 0x80, "state": "uncommitted" },
    {:},
  ]
  flashlog.append #[1, 2, 3]
  output := read-all flashlog
  expect-equals 3 output.size
  expect-bytes-equal #[7, 8] output[0]
  expect-equals flashlog.max-entry-size output[1].size
  expect-bytes-equal #[1, 2, 3] output[2]

test-repair-all-read:
  flashlog := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ #[0] ], "state": "acked" },
    { "sn": 5, "entries": [ #[0], #[1] ], "state": "acked" },
  ]
  flashlog.append #[1, 2, 3]
  output := read-all flashlog --expected-first-sn=5 + 2
  expect-equals 1 output.size
  expect-bytes-equal #[1, 2, 3] output[0]

test-repair-sn-wraparound:
  max := SN.MASK
  flashlog-0 := TestFlashLog.construct --repair [
    { "sn": max, "entries": [ #[1, 2] ] },
    { "sn": 0,   "entries": [ #[3, 4] ] },
  ]
  output-0 := read-all flashlog-0 --expected-first-sn=max
  expect-equals 2 output-0.size
  expect-bytes-equal #[1, 2] output-0[0]
  expect-bytes-equal #[3, 4] output-0[1]

  flashlog-1 := TestFlashLog.construct --no-repair [
    { "sn": max, "entries": [ #[1, 2] ] },
    {:},
  ]
  flashlog-1.append #[3, 4]
  flashlog-1.reset
  flashlog-1.append #[4, 5, 6]  // This needs the write offset to be correct.
  output-1 := read-all flashlog-1 --expected-first-sn=max
  expect-equals 3 output-1.size
  expect-bytes-equal #[1, 2] output-1[0]
  expect-bytes-equal #[3, 4] output-1[1]
  expect-bytes-equal #[4, 5, 6] output-1[2]

test-repair-on-ack:
  flashlog-0 := TestFlashLog.construct --no-repair --read-page=0 --write-page=8192 [
    { "sn":  4, "entries": [ #[7,  8] ] },
    { "sn":  5, "entries": [ #[9, 17], #[1] ] },
    { "sn": 17, "entries": [ #[4, 2] ] },
  ]
  expect flashlog-0.has-more
  output-0 := {:}
  3.repeat:
    flashlog-0.read: | x sn | output-0[sn] = x
    flashlog-0.acknowledge output-0.keys.last
  expect-structural-equals
      { 4: #[7, 8], 5: #[9, 17], 6: #[1], 17: #[4, 2]}
      output-0
  expect-not flashlog-0.has-more

  flashlog-1 := TestFlashLog.construct --no-repair --read-page=0 --write-page=8192 [
    { "sn": 14, "entries": [ #[7,  8] ] },
    { "sn": 15, "entries": [ #[9, 17], #[1] ] },
    { "sn": 17, "entries": [ #[4, 2], #[3] ], "state": "acked" },
  ]
  expect flashlog-1.has-more
  output-1 := {:}
  2.repeat:
    flashlog-1.read: | x sn | output-1[sn] = x
    flashlog-1.acknowledge output-1.keys.last
  expect-structural-equals
      { 14: #[7, 8], 15: #[9, 17], 16: #[1] }
      output-1
  flashlog-1.append #[2, 3]
  expect-structural-equals
      [ #[2, 3] ]
      read-all flashlog-1 --expected-first-sn=17 + 2

  flashlog-2 := TestFlashLog.construct --no-repair --read-page=0 --write-page=20480 [
    { "sn": 24, "entries": [ #[7,  8] ] },
    { "sn": 25, "entries": [ #[9, 17], #[1] ] },
    { "sn": 37, "entries": [ #[4, 2] ], "state": "uncommitted" },
    {:},
    { "sn": 40, "entries": [ #[5] ] },
    { "sn": 41, "entries": [ ], "state": "uncommitted" },
  ]
  expect flashlog-2.has-more
  output-2 := {:}
  2.repeat:
    flashlog-2.read: | x sn | output-2[sn] = x
    flashlog-2.acknowledge output-2.keys.last
  expect-structural-equals
      { 24: #[7, 8], 25: #[9, 17], 26: #[1] }
      output-2
  flashlog-2.append #[7, 9]
  expect-structural-equals
      [ #[5], #[7, 9] ]
      read-all flashlog-2 --expected-first-sn=40

test-invalid-page-start:
  [ -4096, -1, 1, 4000, 4097, 8191, 8192, 12288, 12289 ].do:
    test-invalid-page-start it

test-invalid-page-start page/int:
  flashlog-0 := TestFlashLog.construct --repair --read-page=page --write-page=0 [
    { "sn": 4, "entries": [ #[17] ], "state": "acked" },
    { "sn": 5, "entries": [ #[1], #[2] ], "state": "uncommitted" },
  ]
  expect-equals 4096 flashlog-0.read-page_
  expect-equals 4096 flashlog-0.write-page_

  flashlog-1 := TestFlashLog.construct --repair --read-page=0 --write-page=page [
    { "sn": 4, "entries": [ #[17] ], "state": "acked" },
    { "sn": 5, "entries": [ #[1], #[2] ], "state": "uncommitted" },
  ]
  expect-equals 4096 flashlog-1.read-page_
  expect-equals 4096 flashlog-1.write-page_

test-invalid-write-offset:
  [ -10000, -100, 0, 100, 345, FlashLog.HEADER-SIZE_, 4096, 4200, 8192].do:
    test-invalid-write-offset it

test-invalid-write-offset offset/int:
  // Joined RW, uncommitted.
  flashlog-0 := TestFlashLog.construct --no-repair --read-page=4096 --write-page=4096 --write-offset=offset [
    { "sn": 4, "entries": [ #[17] ], "state": "acked" },
    { "sn": 5, "entries": [ #[1], #[2] ], "state": "uncommitted" },
  ]
  expect-equals 4096 flashlog-0.read-page_
  expect-equals 4096 flashlog-0.write-page_
  flashlog-0.append #[1, 2, 3]
  expect-structural-equals
      [ #[1], #[2], #[1, 2, 3] ]
      read-all flashlog-0 --expected-first-sn=5

  // Joined RW, committed.
  flashlog-1 := TestFlashLog.construct --no-repair --read-page=4096 --write-page=4096 --write-offset=offset [
    { "sn": 7, "entries": [ #[17] ], "state": "acked" },
    { "sn": 8, "entries": [ #[1], #[2] ] },
    {:},
  ]
  expect-equals 4096 flashlog-1.read-page_
  expect-equals 4096 flashlog-1.write-page_
  flashlog-1.append #[1, 2, 3]
  expect-structural-equals
      [ #[1], #[2], #[1, 2, 3] ]
      read-all flashlog-1 --expected-first-sn=8

  // Split RW, uncommitted.
  flashlog-2 := TestFlashLog.construct --no-repair --read-page=0 --write-page=4096 --write-offset=offset [
    { "sn":  9, "entries": [ #[1, 2], #[9] ] },
    { "sn": 11, "entries": [ #[1], #[2] ], "state": "uncommitted" },
  ]
  expect-equals 0 flashlog-2.read-page_
  expect-equals 4096 flashlog-2.write-page_
  flashlog-2.append #[5, 4, 3]
  expect-structural-equals
      [ #[1, 2], #[9], #[1], #[2], #[5, 4, 3] ]
      read-all flashlog-2 --expected-first-sn=9

  // Split RW, committed.
  flashlog-3 := TestFlashLog.construct --no-repair --read-page=0 --write-page=4096 --write-offset=offset [
    { "sn": 17, "entries": [ #[1, 2] ] },
    { "sn": 18, "entries": [ #[99], #[87] ] },
    {:}
  ]
  expect-equals 0 flashlog-3.read-page_
  expect-equals 4096 flashlog-3.write-page_
  flashlog-3.append #[5, 4, 3]
  expect-structural-equals
      [ #[1, 2], #[99], #[87], #[5, 4, 3] ]
      read-all flashlog-3 --expected-first-sn=17

validate-round-trip flashlog/TestFlashLog input/List --append/bool=true -> none:
  if append: input.do: flashlog.append it
  output := read-all flashlog
  output.size.repeat:
    expect-bytes-equal input[it] output[it]

read-all flashlog/TestFlashLog --expected-first-sn/int?=null -> List:
  output := {:}
  while flashlog.has-more:
    last-sn := null
    flashlog.read: | x sn |
      // We can have duplicates, but if the sequence number is
      // the same, we should have the same content.
      if output.contains sn:
        expect-bytes-equal output[sn] x
      else:
        output[sn] = x
      last-sn = sn
    flashlog.acknowledge last-sn

  // Validate the sequence numbers.
  if expected-first-sn:
    expect-equals expected-first-sn output.keys.first
  last-sn/int? := null
  output.keys.do: | sn |
    if last-sn: expect-equals (SN.next last-sn) sn
    last-sn = sn

  return output.values

class TestFlashLog extends FlashLog:
  static COUNTER := 0
  path_/string? := ?

  static constructed_ ::= []

  constructor pages/int:
    path_ = "toit.io/test-flashlog-$(COUNTER++)"
    region := storage.Region.open --flash path_ --capacity=pages * 4096
    super region
    constructed_.add this

  static close-all -> none:
    constructed_.do: it.close
    constructed_.clear

  close:
    if not path_: return
    region_.close  // TODO(kasper): This is a bit annoying.
    storage.Region.delete --flash path_
    path_ = null

  max-entry-size -> int:
    return ((capacity-per-page_ - FlashLog.HEADER-SIZE_ - 1) * 7 + 6) / 8

  has-more -> bool:
    // TODO(kasper): Handle reading from ack'ed pages. We
    // have an invariant that makes it impossible to get
    // to this point, but we should handle it gracefully.
    with-buffer_: | buffer/ByteArray |
      assert: FlashLog.HEADER-SIZE_ + 1 < 16
      region_.read --from=read-page_ buffer[..16]
      if (buffer[FlashLog.HEADER-SIZE_] & 0xc0) == 0x80: return true
    return false

  /**
  Reads from the first unacknowledged page.
  */
  read [block] -> none:
    with-buffer_: | buffer/ByteArray |
      commit-and-read_ buffer read-page_: | sn count | null
      decode buffer block

  /**
  Decodes the given buffer.
  */
  decode buffer/ByteArray [block] -> none:
    sn := LITTLE-ENDIAN.uint32 buffer FlashLog.HEADER-SN-OFFSET_
    cursor := FlashLog.HEADER-SIZE_
    while true:
      from := cursor
      to := cursor

      acc := buffer[cursor++]
      if acc == 0xff: return

      bits := 6
      acc &= 0x3f
      while true:
        if bits < 8:
          next := (cursor >= buffer.size) ? 0xff : buffer[cursor]
          if (next & 0x80) != 0:
            // We copy the section because we're reusing buffers
            // and it is very unfortunate to change the sections
            // we have already handed out.
            block.call (buffer.copy from to) sn
            if next == 0xff: return
            sn = SN.next sn
            break
          acc |= (next << bits)
          bits += 7
          cursor++
          continue
        buffer[to++] = (acc & 0xff)
        acc >>= 8
        bits -= 8

  reset -> bool:
    read-page_ = -1
    write-page_ = -1
    write-offset_ = -1
    return with-buffer_: ensure-valid_ it

  dump -> none:
    with-buffer_: | buffer/ByteArray |
      for page := 0; page < capacity; page += capacity-per-page_:
        banner := ?
        if page == read-page_ and page == write-page_:
          banner = "RW"
        else if page == write-page_:
          banner = " W"
        else if page == read-page_:
          banner = "R "
        else:
          banner = "  "

        is-committed-page_ page buffer: | sn is-acked count |
          if is-acked:
            print "- page $(%06x page):   committed $banner (sn=$(%08x sn), count=$(%04d count)) | ack'ed"
          else:
            print "- page $(%06x page):   committed $banner (sn=$(%08x sn), count=$(%04d count))"
          continue
        is-uncommitted-page_ page buffer: | sn |
          region_.read --from=page buffer
          count := decode-count_ buffer
          print "- page $(%06x page): uncommitted $banner (sn=$(%08x sn), count=$(%04d count))"
          continue
        print "- page $(%06x page): ########### $banner (sn=$("?" * 8), count=$("?" * 4))"

  static construct description/List -> TestFlashLog
      --read-page/int?=null
      --write-page/int?=null
      --write-offset/int?=null
      --reset/bool=false
      --repair/bool=false:
    log := TestFlashLog description.size
    page-size := log.capacity-per-page_
    buffer := ByteArray page-size
    description.size.repeat: | index/int |
      page/Map := description[index]
      region := log.region_
      region.erase --from=index * page-size --to=(index + 1) * page-size

      sn := page.get "sn" --if-absent=: SN.new
      assert: FlashLog.HEADER-MARKER-OFFSET_ == 0 and FlashLog.HEADER-SN-OFFSET_ == 4
      LITTLE-ENDIAN.put-uint32 buffer FlashLog.HEADER-MARKER-OFFSET_ FlashLog.MARKER_
      LITTLE-ENDIAN.put-uint32 buffer FlashLog.HEADER-SN-OFFSET_ sn
      region.write --from=(index * page-size + FlashLog.HEADER-MARKER-OFFSET_)
          buffer[.. FlashLog.HEADER-SN-OFFSET_ + 4]

      state := page.get "state"
      if state and state != "acked" and state != "uncommitted":
        throw "illegal state: $state"

      write-count := null
      write-cursor := FlashLog.HEADER-SIZE_
      if page.contains "bytes":
        if page.contains "entries": throw "cannot have both bytes and entries"
        bytes := page["bytes"]
        region.write --from=(index * page-size + write-cursor) bytes
        write-cursor += bytes.size
        // Compute a correct write count based on the bytes.
        region.read --from=(index * page-size) buffer
        write-count = log.decode-count_ buffer
      else if page.contains "entries":
        entries := page["entries"]
        write-count = 0
        entries.do: | bytes/ByteArray |
          size := log.encode-next_ buffer bytes
          region.write --from=(index * page-size + write-cursor) buffer[..size]
          write-cursor += size
          write-count++
      if write-cursor > page-size: throw "page overflow"

      remaining := page-size - write-cursor
      if remaining > 0:
        fill := page.get "fill" --if-absent=: write-count and 0xff
        if fill:
          buffer[..remaining].fill fill
        else:
          remaining.repeat: buffer[it] = random 0x100
        region.write --from=(index * page-size + write-cursor) buffer[..remaining]

      count := page.get "count"
      if count:
        assert: not state
      else if state == "acked":
        count = 0
      else if state == "uncommitted":
        count = 0xffff
      else:
        count = write-count or (random 0x10000)

      LITTLE-ENDIAN.put-uint16 buffer 0 count
      region.write --from=(index * page-size + FlashLog.HEADER-COUNT-OFFSET_) buffer[..2]

      checksum := page.get "checksum"
      if checksum:
        assert: state != "uncommitted"
      else if state == "uncommitted":
        checksum = 0xffff_ffff
      else:
        region.read --from=(index * page-size) buffer
        crc32 := crc.Crc32
        LITTLE-ENDIAN.put-uint32 buffer FlashLog.HEADER-CHECKSUM-OFFSET_ 0xffff_ffff
        LITTLE-ENDIAN.put-uint16 buffer FlashLog.HEADER-COUNT-OFFSET_ 0xffff
        crc32.add buffer
        checksum = crc32.get-as-int

      LITTLE-ENDIAN.put-uint32 buffer 0 checksum
      region.write --from=(index * page-size + FlashLog.HEADER-CHECKSUM-OFFSET_) buffer[..4]

    if reset:
      assert: not (read-page or write-page or write-offset)
      repaired := log.reset
      expect-equals repair repaired
    else:
      if read-page: log.read-page_ = read-page
      if write-page: log.write-page_ = write-page
      if write-offset or write-page: log.write-offset_ = write-offset or write-page + FlashLog.HEADER-SIZE_
      repaired := log.ensure-valid_ buffer
      expect-equals repair repaired

    return log
