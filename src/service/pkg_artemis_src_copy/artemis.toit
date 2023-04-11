// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services show ServiceResourceProxy

import .api as api
import .implementation.container as implementation

artemis_client_/api.ArtemisClient? ::= (api.ArtemisClient).open
    --if_absent=: null

/**
Whether the Artemis service is available.
*/
available -> bool:
  return artemis_client_ != null

/**
Returns the version of the Artemis service.
*/
version -> string:
  client := artemis_client_
  if not client: throw "Artemis unavailable"
  return client.version

/**
A container is a schedulable unit of execution that runs
  in isolation from the system and the other containers
  on a device.

The containers on a device are managed by Artemis. They
  are installed and uninstalled when Artemis synchronizes
  with the cloud. After a container has been installed
  on a device, Artemis takes care of scheduling it based
  on its triggers and flags.

Use $Container.current to get access to the currently
  executing container.
*/
interface Container:
  /**
  Returns the currently executing container.
  */
  static current ::= implementation.ContainerCurrent

  /**
  Restarts this container.

  If a $delay is provided, Artemis will try to delay the
    restart for the specified amount of time. The container
    may restart early on exceptional occasions, such as a
    reboot after the loss of power.

  If no other jobs are keeping the device busy, delayed
    restarts allow Artemis to reduce power consumption by
    putting the device into a power-saving sleep mode.
  */
  restart --delay/Duration?=null -> none

/**
...

Only one reader. Multiple writers.
*/
class Channel extends ServiceResourceProxy:
  topic/string

  buffer_/ByteArray? := null
  cursor_/int? := null

  pages_/Deque := Deque

  unacked_count_/int := 0
  acks_/int := 0

  constructor.internal_ client/api.ArtemisClient handle/int --.topic:
    super client handle

  static open --topic/string -> Channel:
    client := artemis_client_
    if not client: throw "Artemis unavailable"
    handle := client.channel_open --topic=topic
    return Channel.internal_ client handle --topic=topic

  // something about how much is available
  // something about how much is buffered
  // receive - blocking
  // receive - only latest

  position -> Position:
    pages := pages_
    if not pages.is_empty:
      // TODO(kasper): Handle wrap around.
      first/Page_ := pages.first
      return Position.internal_ first.sn + unacked_count_
    assert: unacked_count_ == 0
    receive_page_: | sn buffer | return Position.internal_ sn
    unreachable

  send bytes/ByteArray -> none:
    (client_ as api.ArtemisClient).channel_send handle_ bytes

  /**
  Receives the next entry in the channel.

  Throws an exception if the channel was found to be corrupt
    during the reading.
  */
  receive -> ByteArray?:  // TODO(kasper): Add wait flag!
    receive_page_: | sn buffer |
      next := receive_next_ buffer
      if next:
        unacked_count_++
      else:
        receive_page_: | sn buffer |
          next = buffer and receive_next_ buffer
          if next: unacked_count_++
      return next
    unreachable

  acknowledge n/int=1 -> none:
    if n < 1: throw "Bad Argument"
    acks := acks_ + n
    unacked_count := unacked_count_
    if acks > unacked_count: throw "OUT_OF_RANGE: $acks > $unacked_count"
    acks_ = acks

    // Ack all the pages we can.
    pages := pages_
    while not pages.is_empty:
      // Don't acknowledge the page unless we're
      // completely done with it.
      first/Page_ := pages.first
      count := first.count
      if acks < count: return

      (client_ as api.ArtemisClient).channel_acknowledge handle_ first.sn count
      unacked_count_ -= count
      acks_ = acks = acks - count
      pages.remove_first

  // TODO(kasper): Poor name.
  receive_page_ [block] -> any:
    buffer := buffer_
    pages := pages_
    if cursor_: return block.call pages.last.sn buffer

    // We have read the entire last page. We can reuse the
    // buffer if it has already been acked.
    peek := pages.size
    result := (client_ as api.ArtemisClient).channel_receive_page handle_
        --peek=peek
        --buffer=(peek == 0) ? buffer : null
    sn := result[0]
    count := result[2]
    buffer_ = buffer = result[3]
    if count == 0: return block.call sn null

    // Got another non-empty page. Wonderful!
    cursor_ = result[1]
    pages.add (Page_ --sn=sn --count=count)
    return block.call sn buffer

  receive_next_ buffer/ByteArray -> ByteArray?:
    cursor := cursor_
    from := cursor
    to := cursor

    acc := buffer[cursor++]
    if acc == 0xff:
      cursor_ = null  // Read last entry.
      return null

    bits := 6
    acc &= 0x3f
    while true:
      while bits < 8:
        if cursor >= buffer.size:
          cursor_ = null  // Read last entry.
          return buffer[from..to]
        next := buffer[cursor]
        if (next & 0x80) != 0:
          cursor_ = cursor
          return buffer[from..to]
        acc |= (next << bits)
        bits += 7
        cursor++
      buffer[to++] = (acc & 0xff)
      acc >>= 8
      bits -= 8

class Position implements Comparable:
  static BITS_ ::= 30
  static MASK_ ::= (1 << BITS_) - 1
  static HALF_ ::= (1 << (BITS_ - 1))

  value/int
  constructor.internal_ value/int:
    this.value = value & MASK_

  stringify -> string:
    return "$(%08x value)"

  operator + n/int -> Position:
    return Position.internal_ value + n

  operator - n/int -> Position:
    return Position.internal_ value - n

  operator == other/any -> bool:
    return other is Position and value == other.value

  operator < other/Position -> bool:
    return (compare value other.value) < 0

  operator <= other/Position -> bool:
    return (compare value other.value) <= 0

  operator > other/Position -> bool:
    return (compare value other.value) > 0

  operator >= other/Position -> bool:
    return (compare value other.value) >= 0

  /**
  Compares this position to $other.

  Returns -1, 0, or 1 if the $this is less than, equal to, or
    greater than $other, respectively.

  Positions wrap around when they reach the representable limit
    while still supporting comparison. If positions are close
    together, then they use normal comparison. However, when they
    are far apart, then they have wrapped around which means that
    the smaller number is considered greater than the larger number.
  */
  compare_to other/Position -> int:
    return compare value other.value

  /**
  Variant of $(compare_to other).

  Calls $if_equal if this and $other are equal. Then returns the
    result of the call.
  */
  compare_to other/Position [--if_equal] -> int:
    result := compare value other.value
    if result == 0: result = if_equal.call
    return result

  static compare p0/int p1/int -> int:
    if p0 == p1: return 0
    return p0 < p1
      ? (p1 - p0 < HALF_ ? -1 :  1)
      : (p0 - p1 < HALF_ ?  1 : -1)

class Page_:
  sn/int
  count/int
  constructor --.sn --.count:
