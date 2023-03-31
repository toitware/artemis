// Copyright (C) 2023 Toitware ApS.

import artemis.service.flashlog show FlashLog SN

import binary show LITTLE_ENDIAN
import crypto.crc
import expect show *
import system.storage

main:
  test_empty
  test_sn_compare
  test_first_read
  test_small
  test_large_append
  test_append_while_reading
  test_illegal_operations_while_reading
  test_continue
  test_avoid_double_read
  test_all_committed
  test_fill_up
  test_full
  test_repeated
  test_illegal_ack
  test_randomized

  test_valid_w_corrupt

  test_valid_joined_rw_committed
  test_valid_joined_rw_committed_page_ordering
  test_valid_joined_rw_uncommitted

  test_valid_split_invalid
  test_valid_split_w_committed
  test_valid_split_w_uncommitted
  test_valid_split_w_page_ordering
  test_valid_split_r_page_ordering

  test_repair_none
  test_repair_committed_first
  test_repair_committed_range
  test_repair_sequence
  test_repair_committed_wrong_order
  test_repair_corrupt_uncommitted_page
  test_repair_full_uncommitted_page
  test_repair_all_read
  test_repair_sn_wraparound
  test_repair_on_ack

  test_invalid_page_start
  test_invalid_write_offset

test_empty:
  flashlog := TestFlashLog 2
  expect_not flashlog.has_more
  flashlog.read: expect false

  flashlog = TestFlashLog 3
  expect_not flashlog.has_more
  flashlog.read: expect false

test_sn_compare:
  expect_equals -1 (SN.compare 1 2)
  expect_equals  0 (SN.compare 2 2)
  expect_equals  1 (SN.compare 2 1)

  max := SN.MASK
  expect_equals  1 (SN.compare (SN.next max) max)
  expect_equals -1 (SN.compare max (SN.next max))
  expect_equals  0 (SN.compare (SN.previous 0) max)

test_first_read:
  flashlog := TestFlashLog 2
  flashlog.append #[1, 2, 3]
  expect flashlog.has_more

  called := false
  flashlog.read:
    expect_bytes_equal #[1, 2, 3] it
    called = true
  expect called

test_small:
  expect_throw "Must have space for two pages": TestFlashLog 1

  flashlog := TestFlashLog 2
  100.repeat:
    input := List 20: ByteArray (random 25) + 1: random 0x100
    validate_round_trip flashlog input
    expect_not flashlog.has_more

test_large_append:
  flashlog := TestFlashLog 2
  flashlog.append (ByteArray flashlog.max_entry_size)
  too_large := ByteArray flashlog.max_entry_size + 1
  expect_throw "Bad Argument": flashlog.append too_large

  // It is a bit nasty, but here we reach into the internals
  // of the FlashLog implementation to test that writing
  // more than the max entry size would indeed overflow.
  buffer := ByteArray flashlog.size_per_page_ + 1024
  written := (flashlog.encode_next_ buffer too_large)
  expect written > (flashlog.size_per_page_ - FlashLog.HEADER_SIZE_)

test_append_while_reading:
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
  expect_list_equals input output

test_illegal_operations_while_reading:
  flashlog := TestFlashLog 2
  input := [#[7, 9, 13], #[17, 19]]
  input.do: flashlog.append it

  output := []
  last := null
  flashlog.read: | x sn |
    output.add x
    expect_throw "INVALID_STATE": flashlog.read: null
    expect_throw "INVALID_STATE": flashlog.has_more
    expect_throw "INVALID_STATE": flashlog.acknowledge sn
    last = sn
  flashlog.acknowledge last
  expect_list_equals input output
  expect_not flashlog.has_more

test_continue:
  flashlog := TestFlashLog 4
  flashlog.reset
  expect_not flashlog.has_more

  input := [
    #[1, 2, 3, 4],
    #[2, 3, 4],
    #[3, 4, 5, 6, 7],
  ]
  flashlog.append input[0]
  flashlog.append input[1]
  flashlog.reset
  expect flashlog.has_more
  flashlog.append input[2]
  count := 0

  flashlog.read:
    expect_bytes_equal input[count] it
    count++
  expect_equals 3 count

  flashlog.reset
  100.repeat:
    input.do: flashlog.append it
    if it % 21 == 0: flashlog.reset

  count = 0
  while flashlog.has_more:
    last := null
    flashlog.read: | _ sn |
      count++
      last = sn
    flashlog.acknowledge last
  expect_equals 3 + (input.size * 100) count

test_avoid_double_read:
  flashlog := TestFlashLog 2
  flashlog.append #[3, 4, 5, 6]
  flashlog.reset
  expect flashlog.has_more

  last := null
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last
  expect_not flashlog.has_more

  flashlog.reset
  expect_not flashlog.has_more

  flashlog.append #[1, 2, 3]
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last
  flashlog.append #[2, 3, 4]
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last
  expect_not flashlog.has_more

  flashlog.reset
  expect_not flashlog.has_more

test_all_committed:
  first := #[3, 4, 5, 6]
  second := #[2, 3, 4, 5]

  flashlog := TestFlashLog 2
  flashlog.append first
  flashlog.read: null  // Commit first page.

  last := null
  flashlog.append second
  flashlog.read: | x sn |
    expect_bytes_equal first x
    last = sn

  flashlog.acknowledge last
  flashlog.read: null  // Commit second page.

  flashlog.reset
  expect flashlog.has_more

  flashlog.read: | x sn |
    expect_bytes_equal second x
    last = sn
  flashlog.acknowledge last

test_fill_up:
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
  expect_equals 3 count

test_full:
  flashlog := TestFlashLog 2
  2.repeat:
    flashlog.append (ByteArray 1700)
    flashlog.append (ByteArray 1700)
  expect_throw "OUT_OF_BOUNDS": flashlog.append (ByteArray 1700)

test_repeated:
  flashlog := TestFlashLog 8
  20.repeat:
    // The worst case is that all the byte arrays are encoded as
    // 29 byte sequences, which means we only have room for 140
    // of them in each page. We need 8 pages for 1000 of those.
    input := List 1000: ByteArray (random 25) + 1: random 0x100
    validate_round_trip flashlog input
    expect_not flashlog.has_more

test_illegal_ack:
  flashlog := TestFlashLog 4
  expect_throw "Cannot acknowledge unread page": flashlog.acknowledge 0

  flashlog.append (ByteArray 100: random 100)
  expect_throw "Cannot acknowledge unread page": flashlog.acknowledge 0
  expect_equals 1 (read_all flashlog).size

  flashlog.append (ByteArray 100: random 100)
  expect_throw "Cannot acknowledge unread page": flashlog.acknowledge 0

  last := null
  flashlog.read: | _ sn | last = sn
  expect_throw "Bad Argument": flashlog.acknowledge -1
  expect_throw "Bad Argument": flashlog.acknowledge -100
  expect_throw "Bad Argument": flashlog.acknowledge last - 1
  expect_throw "Bad Argument": flashlog.acknowledge last - 100
  expect_throw "Bad Argument": flashlog.acknowledge last + 1
  expect_throw "Bad Argument": flashlog.acknowledge last + 100
  expect_throw "Bad Argument": flashlog.acknowledge last + 10000

  flashlog.acknowledge last
  expect_not flashlog.has_more

test_randomized:
  100.repeat:
    flashlog := TestFlashLog 8
    if flashlog.has_more:
      flashlog.dump
      expect false --message="Randomized flash logs should be empty"

test_valid_w_corrupt:
  // Corrupt write page (contains garbage at end).
  test_valid_w_corrupt #[0x80, 0x01, 0xff, 0x80]
  test_valid_w_corrupt #[0x80, 0x02, 0xff, 0xfe]
  test_valid_w_corrupt #[0x80, 0x03, 0xff, 0x80, 0x04]
  test_valid_w_corrupt #[0x80, 0x05, 0xff, 0xfe, 0x06]

test_valid_w_corrupt write_page_bytes/ByteArray:
  // Joined RW, uncommitted.
  flashlog_0 := TestFlashLog.construct --repair --read_page=4096 --write_page=4096 [
    { "sn": 4, "entries": [ #[9, 8, 7] ], "state": "acked" },
    { "sn": 5, "bytes": write_page_bytes, "state": "uncommitted" },
  ]
  expect_equals 4096 flashlog_0.read_page_
  expect_equals 4096 flashlog_0.write_page_
  flashlog_0.append #[1, 2, 3]
  expect_structural_equals
      [ #[1, 2, 3] ]
      read_all flashlog_0 --expected_first_sn=4 + 1

  // Joined RW, committed.
  flashlog_1 := TestFlashLog.construct --repair --read_page=0 --write_page=0 [
    { "sn": 5, "bytes": write_page_bytes },
    {:}
  ]
  expect_equals 0 flashlog_1.read_page_
  expect_equals 0 flashlog_1.write_page_
  expect_not flashlog_1.has_more  // Should have been reset.
  flashlog_1.append #[1, 2, 3]
  expect_structural_equals
      [ #[1, 2, 3] ]
      read_all flashlog_1 --expected_first_sn=5 + 1

  // Split RW, uncommitted.
  flashlog_2 := TestFlashLog.construct --repair --read_page=0 --write_page=4096 [
    { "sn": 9, "entries": [ #[1, 2], #[9] ] },
    { "sn": 11, "bytes": write_page_bytes, "state": "uncommitted" },
  ]
  expect_equals 0 flashlog_2.read_page_
  expect_equals 4096 flashlog_2.write_page_
  expect_structural_equals
      [ #[1, 2], #[9] ]
      read_all flashlog_2 --expected_first_sn=9

  // Split RW, committed.
  flashlog_3 := TestFlashLog.construct --repair --read_page=4096 --write_page=8192 [
    {:},
    { "sn": 7, "entries": [ #[1, 2] ]},
    { "sn": 8, "bytes": write_page_bytes },
  ]
  expect_equals 0 flashlog_3.read_page_   // Repaired by resetting.
  expect_equals 0 flashlog_3.write_page_  // Repaired by resetting.
  expect_not flashlog_3.has_more  // Should have been reset.
  flashlog_3.append #[7, 8, 9]
  expect_structural_equals
      [ #[7, 8, 9] ]
      read_all flashlog_3 --expected_first_sn=8 + 1

test_valid_joined_rw_committed:
  flashlog_0 := TestFlashLog.construct --repair --read_page=0 --write_page=0 [
    { "sn": 4, "entries": [ #[0] ]},  // Should be read page.
    { "sn": 5, "entries": [ #[1] ]},  // Should be write page.
    {:},
  ]
  expect_equals 0 flashlog_0.read_page_
  expect_equals 4096 flashlog_0.write_page_

  flashlog_1 := TestFlashLog.construct --no-repair --read_page=0 --write_page=0 [
    { "sn": 4, "entries": [ #[0] ]},
    { "sn": 0, "fill": 0xff, "state": "uncommitted" },  // Uncommitted, invalid.
    {:},
  ]
  expect_equals 0 flashlog_1.read_page_
  expect_equals 0 flashlog_1.write_page_

  flashlog_2 := TestFlashLog.construct --no-repair --read_page=0 --write_page=0 [
    { "sn": 4, "entries": [ #[0] ]},
    { "sn": 9, "fill": 0xff, "state": "uncommitted" },  // Uncommitted, invalid.
    {:},
  ]
  expect_equals 0 flashlog_2.read_page_
  expect_equals 0 flashlog_2.write_page_

test_valid_joined_rw_uncommitted:
  flashlog_0 := TestFlashLog.construct --repair --read_page=0 --write_page=0 [
    { "sn": 7, "fill": 0xff, "state": "uncommitted" },
    { "sn": 5, "entries": [ #[1] ], "state": "acked" },
  ]
  expect_equals 0 flashlog_0.read_page_
  expect_equals 0 flashlog_0.write_page_

  flashlog_1 := TestFlashLog.construct --repair --read_page=0 --write_page=0 [
    { "sn": 7, "fill": 0xff, "state": "uncommitted" },
    {:},
  ]
  expect_equals 0 flashlog_1.read_page_
  expect_equals 0 flashlog_1.write_page_

test_valid_joined_rw_committed_page_ordering:
  flashlog_0 := TestFlashLog.construct --no-repair --read_page=0 --write_page=0 [
    { "sn": 4, "entries": [ #[7, 9] ]},
    { "sn": 4, "entries": [ #[2, 3, 4] ]},
    {:},
  ]
  expect_equals 0 flashlog_0.read_page_
  expect_equals 0 flashlog_0.write_page_
  expect_structural_equals
      [ #[7, 9] ]  // Repairing would ignore the page following the read page.
      read_all flashlog_0

  flashlog_1 := TestFlashLog.construct --no-repair --read_page=0 --write_page=0 [
    { "sn": 4, "entries": [ #[2, 3, 4] ]},
    {:},
    { "sn": 4, "entries": [ #[7, 9] ]},
  ]
  expect_equals 0 flashlog_1.read_page_
  expect_equals 0 flashlog_1.write_page_
  expect_structural_equals
      [ #[2, 3, 4] ]  // Repairing drops the last page.
      read_all flashlog_1

  flashlog_2 := TestFlashLog.construct --repair --read_page=8192 --write_page=8192 [
    { "sn": 4, "entries": [ #[2, 3, 4] ]},
    {:},
    { "sn": 4, "entries": [ #[7, 9] ]},
  ]
  expect_equals 0 flashlog_2.read_page_
  expect_equals 0 flashlog_2.write_page_
  expect_structural_equals
      [ #[2, 3, 4] ]  // Repairing drops the last page.
      read_all flashlog_2

  flashlog_3 := TestFlashLog.construct --repair --read_page=4096 --write_page=4096 [
    { "sn": 4, "entries": [ #[7, 9] ]},
    { "sn": 4, "entries": [ #[2, 3, 4] ]},
    {:},
  ]
  expect_equals 0 flashlog_3.read_page_
  expect_equals 0 flashlog_3.write_page_
  expect_structural_equals
      [ #[7, 9] ]  // Repairing drops the last page.
      read_all flashlog_3

test_valid_split_invalid:
  flashlog_0 := TestFlashLog.construct --repair --read_page=0 --write_page=4096 [
    { "sn": 7, "fill": 0xff, "state": "uncommitted" },
    { "sn": 5, "entries": [ #[1] ], "state": "acked" },
  ]
  expect_equals 0 flashlog_0.read_page_
  expect_equals 0 flashlog_0.write_page_
  expect_equals 0 (read_all flashlog_0).size

  flashlog_1 := TestFlashLog.construct --repair --read_page=4096 --write_page=0 [
    { "sn": 7, "checksum": 0x1234 },
    { "sn": 5, "entries": [ #[7] ] },
  ]
  expect_equals 4096 flashlog_1.read_page_
  expect_equals 4096 flashlog_1.write_page_
  expect_equals 1 (read_all flashlog_1).size

  flashlog_2 := TestFlashLog.construct --repair --read_page=4096 --write_page=0 [
    { "sn": 7, "checksum": 0x1234 },
    { "sn": 5, "entries": [ #[7] ], "state": "acked" },
  ]
  expect_equals 0 flashlog_2.read_page_
  expect_equals 0 flashlog_2.write_page_
  expect_equals 0 (read_all flashlog_2).size

  flashlog_3 := TestFlashLog.construct --repair --read_page=4096 --write_page=0 [
    { "sn": 4, "entries": [ #[8] ] },
    { "sn": 5, "entries": [ #[7] ] },
    {:},
  ]
  expect_equals 0 flashlog_3.read_page_
  expect_equals 4096 flashlog_3.write_page_
  expect_equals 2 (read_all flashlog_3).size

  flashlog_4 := TestFlashLog.construct --repair --read_page=4096 --write_page=8192 [
    { "sn": 6, "entries": [ #[8] ] },
    { "sn": 5, "entries": [ #[7] ] },
    {:},
  ]
  expect_equals 0 flashlog_4.read_page_
  expect_equals 0 flashlog_4.write_page_
  expect_equals 1 (read_all flashlog_4).size

test_valid_split_w_committed:
  flashlog_0 := TestFlashLog.construct --no-repair --read_page=0 --write_page=4096 [
    { "sn": 5, "entries": [ #[1] ] },
    { "sn": 6, "entries": [ #[2] ] },
    { "sn": 9, "fill": 0xff, "state": "uncommitted" },
  ]
  expect_equals 0 flashlog_0.read_page_
  expect_equals 4096 flashlog_0.write_page_
  expect_equals 2 (read_all flashlog_0).size

  flashlog_1 := TestFlashLog.construct --repair --read_page=0 --write_page=4096 [
    { "sn": 5, "entries": [ #[1] ] },
    { "sn": 6, "entries": [ #[2] ] },
    { "sn": 7, "fill": 0xff, "state": "uncommitted" },
  ]
  expect_equals 0 flashlog_1.read_page_
  expect_equals 8192 flashlog_1.write_page_
  expect_equals 2 (read_all flashlog_1).size

  flashlog_2 := TestFlashLog.construct --repair --read_page=0 --write_page=4096 [
    { "sn": 5, "entries": [ #[1] ] },
    { "sn": 6, "entries": [ #[2], #[3] ] },
    { "sn": 8, "entries": [ #[4] ] },
    {:},
  ]
  expect_equals 0 flashlog_2.read_page_
  expect_equals 8192 flashlog_2.write_page_
  expect_equals 4 (read_all flashlog_2).size

  flashlog_3 := TestFlashLog.construct --repair --read_page=0 --write_page=8192 [
    { "sn": 5, "entries": [ #[1] ] },
    {:},
    { "sn": 2, "entries": [ #[2], #[3] ] },
    {:},
  ]
  expect_equals 0 flashlog_3.read_page_
  expect_equals 0 flashlog_3.write_page_
  expect_equals 1 (read_all flashlog_3).size

  flashlog_4 := TestFlashLog.construct --repair --read_page=0 --write_page=8192 [
    { "sn": 1, "entries": [ #[1] ] },
    {:},
    { "sn": 2, "entries": [ ] },
    { "sn": 2, "entries": [ #[2], #[3] ] },
    {:},
  ]
  // This is slightly weird. The repairing didn't pick page 8192 as
  // the new RW page, because it appears ack'ed due to the count
  // being zero.
  expect_equals 12288 flashlog_4.read_page_
  expect_equals 12288 flashlog_4.write_page_
  expect_equals 0 (read_all flashlog_4).size

test_valid_split_w_uncommitted:
  flashlog_0 := TestFlashLog.construct --repair --read_page=0 --write_page=4096 [
    { "sn": 5, "entries": [ #[1] ] },
    { "sn": 4, "entries": [ #[2] ], "state": "uncommitted" },
    {:}
  ]
  expect_equals 0 flashlog_0.read_page_
  expect_equals 0 flashlog_0.write_page_
  expect_equals 1 (read_all flashlog_0).size

  flashlog_1 := TestFlashLog.construct --repair --read_page=0 --write_page=8192 [
    { "sn": 3, "entries": [ #[1] ] },
    {:},
    { "sn": 4, "entries": [ #[2] ], "state": "uncommitted" },
    {:}
  ]
  expect_equals 0 flashlog_1.read_page_
  expect_equals 0 flashlog_1.write_page_
  expect_equals 1 (read_all flashlog_1).size

  flashlog_2 := TestFlashLog.construct --repair --read_page=0 --write_page=8192 [
    { "sn": 3, "entries": [ #[1] ] },
    { "sn": 7, "entries": [ #[3], #[4] ] },
    { "sn": 4, "entries": [ #[2] ], "state": "uncommitted" },
    {:}
  ]
  expect_equals 4096 flashlog_2.read_page_
  expect_equals 4096 flashlog_2.write_page_
  expect_equals 2 (read_all flashlog_2).size

test_valid_split_r_page_ordering:
  // The second entry with SN 5 is ignored when repairing
  // because of its position in the page list. We don't
  // insist on repairing in this case.
  flashlog_0 := TestFlashLog.construct --no-repair --read_page=0 --write_page=8192 [
    { "sn": 5, "entries": [ #[1] ] },
    {:},
    { "sn": 6, "entries": [ #[4], #[3] ] },
    { "sn": 5, "entries": [ #[2] ] },
  ]
  expect_equals 0 flashlog_0.read_page_
  expect_equals 8192 flashlog_0.write_page_
  expect_structural_equals
      [ #[1], #[4], #[3] ]  // Auto-repaired after first page.
      read_all flashlog_0

  flashlog_1 := TestFlashLog.construct --repair --read_page=4096 --write_page=12288 [
    { "sn": 5, "entries": [ #[2] ] },
    { "sn": 5, "entries": [ #[1] ] },
    {:},
    { "sn": 6, "entries": [ #[2], #[3] ] },
  ]
  expect_equals 12288 flashlog_1.read_page_
  expect_equals 12288 flashlog_1.write_page_
  expect_equals 2 (read_all flashlog_1).size

  flashlog_2 := TestFlashLog.construct --repair --read_page=4096 --write_page=16384 [
    { "sn": 5, "entries": [ #[2] ] },
    { "sn": 5, "entries": [ #[1] ] },
    {:},
    { "sn": 5, "entries": [ ] },
    { "sn": 5, "fill": 0xff, "state": "uncommitted" },
  ]
  expect_equals 0 flashlog_2.read_page_
  expect_equals 0 flashlog_2.write_page_
  expect_equals 1 (read_all flashlog_2).size

test_valid_split_w_page_ordering:
  flashlog_0 := TestFlashLog.construct --no-repair --read_page=12288 --write_page=0 [
    { "sn": 6, "entries": [ #[2] ] },
    { "sn": 6, "entries": [ #[1] ] },
    {:},
    { "sn": 4, "entries": [ #[4], #[3] ] },
  ]
  expect_equals 12288 flashlog_0.read_page_
  expect_equals 0 flashlog_0.write_page_
  expect_structural_equals
      [ #[4], #[3], #[2] ]  // Page following write page is ignored.
      read_all flashlog_0

  flashlog_1 := TestFlashLog.construct --repair --read_page=8192 --write_page=12288 [
    { "sn": 6, "entries": [ #[1] ] },
    {:},
    { "sn": 4, "entries": [ #[4], #[3] ] },
    { "sn": 6, "entries": [ #[2] ] },
  ]
  expect_equals 0 flashlog_1.read_page_
  expect_equals 0 flashlog_1.write_page_
  expect_structural_equals
      [ #[1] ]  // Repairing drops the pages after the first one.
      read_all flashlog_1

test_repair_none:
  flashlog := TestFlashLog.construct --no-repair [
    { "sn": 4, "fill": 0xff, "state": "uncommitted" },
    { "sn": 4, "entries": [], "state": "acked" },
  ]
  output := read_all flashlog
  expect_equals 0 output.size

test_repair_committed_first:
  test_repair_committed_first 2
  test_repair_committed_first 3
  test_repair_committed_first 4
  test_repair_committed_first 10

test_repair_committed_first pages/int:
  // Fill all pages.
  flashlog := TestFlashLog pages
  pages.repeat:
    flashlog.append (ByteArray 1700)
    flashlog.append (ByteArray 1700)

  // Acknowledge the first page.
  expect_equals 0 flashlog.read_page_
  last := null
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last

  // Append more data in the first page.
  flashlog.append (ByteArray 1700)
  // It takes the first write to realize that we need
  // to write into the first page.
  expect_equals 0 flashlog.write_page_
  flashlog.append (ByteArray 1700)

  // Make room in the second page by acknowleding it.
  flashlog.read: | _ sn | last = sn
  flashlog.acknowledge last

  // Commit the first page by overflowing it with
  // a too big write.
  flashlog.append (ByteArray 1700)

  flashlog.reset

  count := 0
  while flashlog.has_more:
    last = null
    flashlog.read: | _ sn |
      last = sn
      count++
    flashlog.acknowledge last

  // One page has one entry and the others have two.
  expect_equals ((pages - 1) * 2 + 1) count

test_repair_committed_range:
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
  while flashlog.has_more:
    last := null
    flashlog.read: | _ sn |
      last = sn
      count++
    flashlog.acknowledge last
  expect_equals 7 count

test_repair_sequence:
  input := [
    #[1, 2, 3],
    #[2, 3],
  ]

  flashlog_0 := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ input[0] ] },
    { "sn": 5, "entries": [ input[1] ] },
  ]
  validate_round_trip flashlog_0 input --no-append

  flashlog_1 := TestFlashLog.construct --repair [
    { "sn": 5, "entries": [ input[1] ] },
    { "sn": 4, "entries": [ input[0] ] },
  ]
  validate_round_trip flashlog_1 input --no-append

  flashlog_2 := TestFlashLog.construct --repair [
    { "sn": 5, "entries": [ input[1] ] },
    {:},
    { "sn": 4, "entries": [ input[0] ] },
  ]
  validate_round_trip flashlog_2 input --no-append

  flashlog_3 := TestFlashLog.construct --repair [
    {:},
    { "sn": 5, "entries": [ input[0] ] },
    { "sn": 4, "entries": [ #[0xab, 0xbc]] },
    {:},
  ]
  validate_round_trip flashlog_3 input[..1] --no-append

  flashlog_4 := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ #[0xab, 0xbc]] },
    {:},
    { "sn": 5, "entries": [ input[0] ] },
  ]
  validate_round_trip flashlog_4 input[..1] --no-append

test_repair_committed_wrong_order:
  test_repair_committed_wrong_order 0 0
  test_repair_committed_wrong_order 5 5
  test_repair_committed_wrong_order SN.MASK SN.MASK

  test_repair_committed_wrong_order 5 4
  test_repair_committed_wrong_order 5 2
  test_repair_committed_wrong_order 5 SN.MASK
  test_repair_committed_wrong_order SN.MASK (SN.MASK - 100)

test_repair_committed_wrong_order sn0/int sn1/int:
  expect (SN.compare sn0 sn1) >= 0

  flashlog_0 := TestFlashLog.construct --repair [
    // Ack'ed page, followed by a non-acked page with lower
    // sequence number.
    { "sn": sn0, "entries": [ #[7] ], "state": "acked" },
    { "sn": sn1, "entries": [ #[8] ] },
  ]
  output_0 := read_all flashlog_0
  expect_equals 0 output_0.size
  flashlog_0.append #[9]
  expect_structural_equals [#[9]] (read_all flashlog_0 --expected_first_sn=(SN.next sn0))

  flashlog_1 := TestFlashLog.construct --repair [
    // Ack'ed page, followed by another acked page with lower
    // sequence number.
    { "sn": sn0, "entries": [ #[7] ], "state": "acked" },
    { "sn": sn1, "entries": [ #[8] ], "state": "acked" },
  ]
  output_1 := read_all flashlog_1
  expect_equals 0 output_1.size
  flashlog_1.append #[23]
  expect_structural_equals [#[23]] (read_all flashlog_1 --expected_first_sn=(SN.next sn0))

test_repair_corrupt_uncommitted_page:
  input := [
    #[7, 9, 13],
    #[2, 3, 5, 7],
  ]

  flashlog_0 := TestFlashLog.construct --repair  [
    { "sn": 4, "entries": [ input[0] ] },
    // Uncommitted, corrupt page (first entry doesn't have the MSB set).
    { "sn": 5, "bytes": #[0], "state": "uncommitted" },
  ]
  flashlog_0.append input[1]
  validate_round_trip flashlog_0 input --no-append

  flashlog_1 := TestFlashLog.construct --repair  [
    // Uncommitted, corrupt page (first entry doesn't have the MSB set).
    { "sn": 5, "bytes": #[0], "state": "uncommitted" },
    { "sn": 4, "entries": [ input[0] ] },
  ]
  flashlog_1.append input[1]
  validate_round_trip flashlog_1 input --no-append

  flashlog_2 := TestFlashLog.construct --repair [
    // Uncommitted, corrupt page (first entry doesn't have the MSB set).
    { "sn": 5, "bytes": #[0], "state": "uncommitted" },
    {:},
    { "sn": 4, "entries": [ input[0] ] },
  ]
  flashlog_2.append input[1]
  validate_round_trip flashlog_2 input --no-append

  // We need to reset the log here. Otherwise, we will not repair
  // it because the validation will find that the uncommitted page
  // is corrupt and ignore it.
  flashlog_3 := TestFlashLog.construct --reset --repair [
    { "sn": 4, "entries": [ input[0] ] },
    // Uncommitted, corrupt page (count isn't cleared).
    { "sn": 5, "entries": [ input[1] ], "count": 0xfeff, "checksum": 0xffff_ffff },
  ]
  flashlog_3.append input[1]
  validate_round_trip flashlog_3 input --no-append

  // We need to reset the log here. Otherwise, we will not repair
  // it because the validation will find that the uncommitted page
  // is corrupt and ignore it.
  flashlog_4 := TestFlashLog.construct --reset --repair [
    { "sn": 4, "entries": [ input[0] ] },
    // Uncommitted, corrupt page (checksum isn't cleared).
    { "sn": 5, "entries": [ input[1] ], "count": 0xffff, "checksum": 0xffff_feff },
  ]
  flashlog_4.append input[1]
  validate_round_trip flashlog_4 input --no-append

  flashlog_5 := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ input[0] ] },
    // Uncommitted, corrupt page (contains garbage at end).
    { "sn": 5, "bytes": #[0x80, 0x00, 0xff, 0xfe], "state": "uncommitted" },
  ]
  flashlog_5.append input[1]
  validate_round_trip flashlog_5 input --no-append

test_repair_full_uncommitted_page:
  flashlog := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ #[7, 8] ] },
    // Uncommitted, full page.
    { "sn": 5, "bytes": #[0x80], "fill": random 0x80, "state": "uncommitted" },
    {:},
  ]
  flashlog.append #[1, 2, 3]
  output := read_all flashlog
  expect_equals 3 output.size
  expect_bytes_equal #[7, 8] output[0]
  expect_equals flashlog.max_entry_size output[1].size
  expect_bytes_equal #[1, 2, 3] output[2]

test_repair_all_read:
  flashlog := TestFlashLog.construct --repair [
    { "sn": 4, "entries": [ #[0] ], "state": "acked" },
    { "sn": 5, "entries": [ #[0], #[1] ], "state": "acked" },
  ]
  flashlog.append #[1, 2, 3]
  output := read_all flashlog --expected_first_sn=5 + 2
  expect_equals 1 output.size
  expect_bytes_equal #[1, 2, 3] output[0]

test_repair_sn_wraparound:
  max := SN.MASK
  flashlog_0 := TestFlashLog.construct --repair [
    { "sn": max, "entries": [ #[1, 2] ] },
    { "sn": 0,   "entries": [ #[3, 4] ] },
  ]
  output_0 := read_all flashlog_0 --expected_first_sn=max
  expect_equals 2 output_0.size
  expect_bytes_equal #[1, 2] output_0[0]
  expect_bytes_equal #[3, 4] output_0[1]

  flashlog_1 := TestFlashLog.construct --no-repair [
    { "sn": max, "entries": [ #[1, 2] ] },
    {:},
  ]
  flashlog_1.append #[3, 4]
  flashlog_1.reset
  flashlog_1.append #[4, 5, 6]  // This needs the write offset to be correct.
  output_1 := read_all flashlog_1 --expected_first_sn=max
  expect_equals 3 output_1.size
  expect_bytes_equal #[1, 2] output_1[0]
  expect_bytes_equal #[3, 4] output_1[1]
  expect_bytes_equal #[4, 5, 6] output_1[2]

test_repair_on_ack:
  flashlog_0 := TestFlashLog.construct --no-repair --read_page=0 --write_page=8192 [
    { "sn":  4, "entries": [ #[7,  8] ] },
    { "sn":  5, "entries": [ #[9, 17], #[1] ] },
    { "sn": 17, "entries": [ #[4, 2] ] },
  ]
  expect flashlog_0.has_more
  output_0 := {:}
  3.repeat:
    flashlog_0.read: | x sn | output_0[sn] = x
    flashlog_0.acknowledge output_0.keys.last
  expect_structural_equals
      { 4: #[7, 8], 5: #[9, 17], 6: #[1], 17: #[4, 2]}
      output_0
  expect_not flashlog_0.has_more

  flashlog_1 := TestFlashLog.construct --no-repair --read_page=0 --write_page=8192 [
    { "sn": 14, "entries": [ #[7,  8] ] },
    { "sn": 15, "entries": [ #[9, 17], #[1] ] },
    { "sn": 17, "entries": [ #[4, 2], #[3] ], "state": "acked" },
  ]
  expect flashlog_1.has_more
  output_1 := {:}
  2.repeat:
    flashlog_1.read: | x sn | output_1[sn] = x
    flashlog_1.acknowledge output_1.keys.last
  expect_structural_equals
      { 14: #[7, 8], 15: #[9, 17], 16: #[1] }
      output_1
  flashlog_1.append #[2, 3]
  expect_structural_equals
      [ #[2, 3] ]
      read_all flashlog_1 --expected_first_sn=17 + 2

  flashlog_2 := TestFlashLog.construct --no-repair --read_page=0 --write_page=20480 [
    { "sn": 24, "entries": [ #[7,  8] ] },
    { "sn": 25, "entries": [ #[9, 17], #[1] ] },
    { "sn": 37, "entries": [ #[4, 2] ], "state": "uncommitted" },
    {:},
    { "sn": 40, "entries": [ #[5] ] },
    { "sn": 41, "entries": [ ], "state": "uncommitted" },
  ]
  expect flashlog_2.has_more
  output_2 := {:}
  2.repeat:
    flashlog_2.read: | x sn | output_2[sn] = x
    flashlog_2.acknowledge output_2.keys.last
  expect_structural_equals
      { 24: #[7, 8], 25: #[9, 17], 26: #[1] }
      output_2
  flashlog_2.append #[7, 9]
  expect_structural_equals
      [ #[5], #[7, 9] ]
      read_all flashlog_2 --expected_first_sn=40

test_invalid_page_start:
  [ -4096, -1, 1, 4000, 4097, 8191, 8192, 12288, 12289 ].do:
    test_invalid_page_start it

test_invalid_page_start page/int:
  flashlog_0 := TestFlashLog.construct --repair --read_page=page --write_page=0 [
    { "sn": 4, "entries": [ #[17] ], "state": "acked" },
    { "sn": 5, "entries": [ #[1], #[2] ], "state": "uncommitted" },
  ]
  expect_equals 4096 flashlog_0.read_page_
  expect_equals 4096 flashlog_0.write_page_

  flashlog_1 := TestFlashLog.construct --repair --read_page=0 --write_page=page [
    { "sn": 4, "entries": [ #[17] ], "state": "acked" },
    { "sn": 5, "entries": [ #[1], #[2] ], "state": "uncommitted" },
  ]
  expect_equals 4096 flashlog_1.read_page_
  expect_equals 4096 flashlog_1.write_page_

test_invalid_write_offset:
  [ -10000, -100, 0, 100, 345, FlashLog.HEADER_SIZE_, 4096, 4200, 8192].do:
    test_invalid_write_offset it

test_invalid_write_offset offset/int:
  // Joined RW, uncommitted.
  flashlog_0 := TestFlashLog.construct --no-repair --read_page=4096 --write_page=4096 --write_offset=offset [
    { "sn": 4, "entries": [ #[17] ], "state": "acked" },
    { "sn": 5, "entries": [ #[1], #[2] ], "state": "uncommitted" },
  ]
  expect_equals 4096 flashlog_0.read_page_
  expect_equals 4096 flashlog_0.write_page_
  flashlog_0.append #[1, 2, 3]
  expect_structural_equals
      [ #[1], #[2], #[1, 2, 3] ]
      read_all flashlog_0 --expected_first_sn=5

  // Joined RW, committed.
  flashlog_1 := TestFlashLog.construct --no-repair --read_page=4096 --write_page=4096 --write_offset=offset [
    { "sn": 7, "entries": [ #[17] ], "state": "acked" },
    { "sn": 8, "entries": [ #[1], #[2] ] },
    {:},
  ]
  expect_equals 4096 flashlog_1.read_page_
  expect_equals 4096 flashlog_1.write_page_
  flashlog_1.append #[1, 2, 3]
  expect_structural_equals
      [ #[1], #[2], #[1, 2, 3] ]
      read_all flashlog_1 --expected_first_sn=8

  // Split RW, uncommitted.
  flashlog_2 := TestFlashLog.construct --no-repair --read_page=0 --write_page=4096 --write_offset=offset [
    { "sn":  9, "entries": [ #[1, 2], #[9] ] },
    { "sn": 11, "entries": [ #[1], #[2] ], "state": "uncommitted" },
  ]
  expect_equals 0 flashlog_2.read_page_
  expect_equals 4096 flashlog_2.write_page_
  flashlog_2.append #[5, 4, 3]
  expect_structural_equals
      [ #[1, 2], #[9], #[1], #[2], #[5, 4, 3] ]
      read_all flashlog_2 --expected_first_sn=9

  // Split RW, committed.
  flashlog_3 := TestFlashLog.construct --no-repair --read_page=0 --write_page=4096 --write_offset=offset [
    { "sn": 17, "entries": [ #[1, 2] ] },
    { "sn": 18, "entries": [ #[99], #[87] ] },
    {:}
  ]
  expect_equals 0 flashlog_3.read_page_
  expect_equals 4096 flashlog_3.write_page_
  flashlog_3.append #[5, 4, 3]
  expect_structural_equals
      [ #[1, 2], #[99], #[87], #[5, 4, 3] ]
      read_all flashlog_3 --expected_first_sn=17

validate_round_trip flashlog/FlashLog input/List --append/bool=true -> none:
  if append: input.do: flashlog.append it
  output := read_all flashlog
  output.size.repeat:
    expect_bytes_equal input[it] output[it]

read_all flashlog/FlashLog --expected_first_sn/int?=null -> List:
  output := {:}
  while flashlog.has_more:
    last_sn := null
    flashlog.read: | x sn |
      // We can have duplicates, but if the sequence number is
      // the same, we should have the same content.
      if output.contains sn:
        expect_bytes_equal output[sn] x
      else:
        output[sn] = x
      last_sn = sn
    flashlog.acknowledge last_sn

  // Validate the sequence numbers.
  if expected_first_sn:
    expect_equals expected_first_sn output.keys.first
  last_sn/int? := null
  output.keys.do: | sn |
    if last_sn: expect_equals (SN.next last_sn) sn
    last_sn = sn

  return output.values

class TestFlashLog extends FlashLog:
  static COUNTER := 0
  path_/string? := ?

  constructor pages/int:
    path_ = "toitlang.org/test-flashlog-$(COUNTER++)"
    region := storage.Region.open --flash path_ --capacity=pages * 4096
    super region
    add_finalizer this:: close

  close:
    if not path_: return
    region_.close  // TODO(kasper): This is a bit annoying.
    storage.Region.delete --flash path_
    path_ = null

  max_entry_size -> int:
    return ((size_per_page_ - FlashLog.HEADER_SIZE_ - 1) * 7 + 6) / 8

  static construct description/List -> TestFlashLog
      --read_page/int?=null
      --write_page/int?=null
      --write_offset/int?=null
      --reset/bool=false
      --repair/bool=false:
    log := TestFlashLog description.size
    page_size := log.size_per_page_
    buffer := ByteArray page_size
    description.size.repeat: | index/int |
      page/Map := description[index]
      region := log.region_
      region.erase --from=index * page_size --to=(index + 1) * page_size

      sn := page.get "sn" --if_absent=: SN.new
      assert: FlashLog.HEADER_MARKER_OFFSET_ == 0 and FlashLog.HEADER_SN_OFFSET_ == 4
      LITTLE_ENDIAN.put_uint32 buffer FlashLog.HEADER_MARKER_OFFSET_ FlashLog.MARKER_
      LITTLE_ENDIAN.put_uint32 buffer FlashLog.HEADER_SN_OFFSET_ sn
      region.write --from=(index * page_size + FlashLog.HEADER_MARKER_OFFSET_)
          buffer[.. FlashLog.HEADER_SN_OFFSET_ + 4]

      state := page.get "state"
      if state and state != "acked" and state != "uncommitted":
        throw "illegal state: $state"

      write_count := null
      write_cursor := FlashLog.HEADER_SIZE_
      if page.contains "bytes":
        if page.contains "entries": throw "cannot have both bytes and entries"
        bytes := page["bytes"]
        region.write --from=(index * page_size + write_cursor) bytes
        write_cursor += bytes.size
        // Compute a correct write count based on the bytes.
        write_count = 0
        region.read --from=(index * page_size) buffer
        read_cursor := FlashLog.HEADER_SIZE_
        while read_cursor < page_size:
          read_cursor = log.decode_next_ buffer read_cursor: write_count++
      else if page.contains "entries":
        entries := page["entries"]
        write_count = 0
        entries.do: | bytes/ByteArray |
          size := log.encode_next_ buffer bytes
          region.write --from=(index * page_size + write_cursor) buffer[..size]
          write_cursor += size
          write_count++
      if write_cursor > page_size: throw "page overflow"

      remaining := page_size - write_cursor
      if remaining > 0:
        fill := page.get "fill" --if_absent=: write_count and 0xff
        if fill:
          buffer[..remaining].fill fill
        else:
          remaining.repeat: buffer[it] = random 0x100
        region.write --from=(index * page_size + write_cursor) buffer[..remaining]

      count := page.get "count"
      if count:
        assert: not state
      else if state == "acked":
        count = 0
      else if state == "uncommitted":
        count = 0xffff
      else:
        count = write_count or (random 0x10000)

      LITTLE_ENDIAN.put_uint16 buffer 0 count
      region.write --from=(index * page_size + FlashLog.HEADER_COUNT_OFFSET_) buffer[..2]

      checksum := page.get "checksum"
      if checksum:
        assert: state != "uncommitted"
      else if state == "uncommitted":
        checksum = 0xffff_ffff
      else:
        region.read --from=(index * page_size) buffer
        crc32 := crc.Crc32
        read_cursor := FlashLog.HEADER_SIZE_
        read_count := 0
        while read_cursor < page_size:
          read_cursor = log.decode_next_ buffer read_cursor:
            crc32.add it
            read_count++
        sn_next := SN.next --increment=read_count (LITTLE_ENDIAN.uint32 buffer FlashLog.HEADER_SN_OFFSET_)
        LITTLE_ENDIAN.put_uint32 buffer 0 sn_next
        crc32.add buffer[..4]
        checksum = crc32.get_as_int

      LITTLE_ENDIAN.put_uint32 buffer 0 checksum
      region.write --from=(index * page_size + FlashLog.HEADER_CHECKSUM_OFFSET_) buffer[..4]

    if reset:
      assert: not (read_page or write_page or write_offset)
      repaired := log.reset
      expect_equals repair repaired
    else:
      if read_page: log.read_page_ = read_page
      if write_page: log.write_page_ = write_page
      if write_offset or write_page: log.write_offset_ = write_offset or write_page + FlashLog.HEADER_SIZE_
      repaired := log.ensure_valid_ buffer
      expect_equals repair repaired

    return log
