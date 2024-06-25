// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services show ServiceSelector ServiceClient
import ..artemis as artemis  // For toitdoc.

interface ArtemisService:
  static SELECTOR ::= ServiceSelector
      --uuid="61d82c0b-7009-4e16-b248-324de4e25f9B"
      --major=1
      --minor=1

  /** The mode used by controllers that want to go online. */
  static CONTROLLER-MODE-ONLINE ::= 0

  /** The mode used by controllers that want to go offline. */
  static CONTROLLER-MODE-OFFLINE ::= 1

  static CHANNEL-POSITION-BITS_ ::= 30
  static CHANNEL-POSITION-HALF_ ::= (1 << (CHANNEL-POSITION-BITS_ - 1))

  /** The mask used to force channel positions to wrap around. */
  static CHANNEL-POSITION-MASK ::= (1 << CHANNEL-POSITION-BITS_) - 1

  /**
  Compares two channel positions.

  See $artemis.ChannelPosition.compare-to for a description
    of how the comparison is performed.
  */
  static channel-position-compare p0/int p1/int -> int:
    if p0 == p1: return 0
    return p0 < p1
      ? (p1 - p0 < CHANNEL-POSITION-HALF_ ? -1 :  1)
      : (p0 - p1 < CHANNEL-POSITION-HALF_ ?  1 : -1)

  version -> string
  static VERSION-INDEX /int ::= 0

  device-id -> ByteArray
  static DEVICE-ID-INDEX /int ::= 7

  synchronized-last-us -> int?
  static SYNCHRONIZED-LAST-US /int ::= 13

  container-current-restart --wakeup-us/int? -> none
  static CONTAINER-CURRENT-RESTART-INDEX /int ::= 1

  container-current-trigger -> int
  static CONTAINER-CURRENT-TRIGGER-INDEX /int ::= 10

  container-current-triggers -> List?
  static CONTAINER-CURRENT-TRIGGERS-INDEX /int ::= 11

  container-current-set-triggers new-triggers/List? -> none
  static CONTAINER-CURRENT-SET-TRIGGERS-INDEX /int ::= 12

  controller-open --mode/int -> int
  static CONTROLLER-OPEN-INDEX /int ::= 6

  channel-open --topic/string --receive/bool -> int?
  static CHANNEL-OPEN-INDEX /int ::= 2

  channel-send handle/int bytes/ByteArray -> bool
  static CHANNEL-SEND-INDEX /int ::= 3

  channel-receive-page handle/int --peek/int --buffer/ByteArray? -> List?
  static CHANNEL-RECEIVE-PAGE-INDEX /int ::= 4

  channel-acknowledge handle/int position/int count/int -> none
  static CHANNEL-ACKNOWLEDGE-INDEX /int ::= 5

  channel-capacity handle/int -> int
  static CHANNEL-CAPACITY-INDEX /int ::= 8

  channel-size handle/int -> int
  static CHANNEL-SIZE-INDEX /int ::= 9

class ArtemisClient extends ServiceClient
    implements ArtemisService:
  static SELECTOR ::= ArtemisService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  version -> string:
    return invoke_ ArtemisService.VERSION-INDEX null

  device-id -> ByteArray:
    return invoke_ ArtemisService.DEVICE-ID-INDEX null

  synchronized-last-us -> int?:
    return invoke_ ArtemisService.SYNCHRONIZED-LAST-US null

  container-current-restart --wakeup-us/int? -> none:
    invoke_ ArtemisService.CONTAINER-CURRENT-RESTART-INDEX wakeup-us

  container-current-trigger -> int:
    return invoke_ ArtemisService.CONTAINER-CURRENT-TRIGGER-INDEX null

  container-current-triggers -> List:
    return invoke_ ArtemisService.CONTAINER-CURRENT-TRIGGERS-INDEX null

  container-current-set-triggers new-triggers/List -> none:
    invoke_ ArtemisService.CONTAINER-CURRENT-SET-TRIGGERS-INDEX new-triggers

  controller-open --mode/int -> int:
    return invoke_ ArtemisService.CONTROLLER-OPEN-INDEX mode

  channel-open --topic/string --receive/bool -> int?:
    return invoke_ ArtemisService.CHANNEL-OPEN-INDEX [topic, receive]

  channel-send handle/int bytes/ByteArray -> bool:
    return invoke_ ArtemisService.CHANNEL-SEND-INDEX [handle, bytes]

  channel-receive-page handle/int --peek/int --buffer/ByteArray? -> List?:
    return invoke_ ArtemisService.CHANNEL-RECEIVE-PAGE-INDEX [handle, peek, buffer]

  channel-acknowledge handle/int position/int count/int -> none:
    invoke_ ArtemisService.CHANNEL-ACKNOWLEDGE-INDEX [handle, position, count]

  channel-capacity handle/int -> int:
    return invoke_ ArtemisService.CHANNEL-CAPACITY-INDEX handle

  channel-size handle/int -> int:
    return invoke_ ArtemisService.CHANNEL-SIZE-INDEX handle
