// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services show ServiceSelector ServiceClient

interface ArtemisService:
  static SELECTOR ::= ServiceSelector
      --uuid="61d82c0b-7009-4e16-b248-324de4e25f9B"
      --major=0
      --minor=3

  static CHANNEL_POSITION_BITS_ ::= 30
  static CHANNEL_POSITION_HALF_ ::= (1 << (CHANNEL_POSITION_BITS_ - 1))
  /** */
  static CHANNEL_POSITION_MASK ::= (1 << CHANNEL_POSITION_BITS_) - 1

  /* */
  static channel_position_compare p0/int p1/int -> int:
    if p0 == p1: return 0
    return p0 < p1
      ? (p1 - p0 < CHANNEL_POSITION_HALF_ ? -1 :  1)
      : (p0 - p1 < CHANNEL_POSITION_HALF_ ?  1 : -1)

  version -> string
  static VERSION_INDEX /int ::= 0

  container_current_restart --wakeup_us/int? -> none
  static CONTAINER_CURRENT_RESTART_INDEX /int ::= 1

  channel_open --topic/string --receive/bool -> int?
  static CHANNEL_OPEN_INDEX /int ::= 2

  channel_send handle/int bytes/ByteArray -> none
  static CHANNEL_SEND_INDEX /int ::= 3

  channel_receive_page handle/int --peek/int --buffer/ByteArray? -> List?
  static CHANNEL_RECEIVE_PAGE_INDEX /int ::= 4

  channel_acknowledge handle/int position/int count/int -> none
  static CHANNEL_ACKNOWLEDGE_INDEX /int ::= 5

class ArtemisClient extends ServiceClient
    implements ArtemisService:
  static SELECTOR ::= ArtemisService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  version -> string:
    return invoke_ ArtemisService.VERSION_INDEX null

  container_current_restart --wakeup_us/int? -> none:
    invoke_ ArtemisService.CONTAINER_CURRENT_RESTART_INDEX wakeup_us

  channel_open --topic/string --receive/bool -> int?:
    return invoke_ ArtemisService.CHANNEL_OPEN_INDEX [topic, receive]

  channel_send handle/int bytes/ByteArray -> none:
    invoke_ ArtemisService.CHANNEL_SEND_INDEX [handle, bytes]

  channel_receive_page handle/int --peek/int --buffer/ByteArray? -> List?:
    return invoke_ ArtemisService.CHANNEL_RECEIVE_PAGE_INDEX [handle, peek, buffer]

  channel_acknowledge handle/int position/int count/int -> none:
    invoke_ ArtemisService.CHANNEL_ACKNOWLEDGE_INDEX [handle, position, count]

