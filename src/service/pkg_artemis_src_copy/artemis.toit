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
*/
class Channel extends ServiceResourceProxy:
  topic/string

  page_/ByteArray? := null
  spare_/ByteArray? := null

  cursor_/int := 0
  count_/int := 0
  acknowledged_/int := 0

  constructor.internal_ client/api.ArtemisClient handle/int --.topic:
    super client handle

  static open --topic/string -> Channel:
    client := artemis_client_
    if not client: throw "Artemis unavailable"
    handle := client.channel_open --topic=topic
    return Channel.internal_ client handle --topic=topic

  send bytes/ByteArray -> none:
    (client_ as api.ArtemisClient).channel_send handle_ bytes

  receive -> ByteArray?:
    if cursor_ == 0:
      if acknowledged_ < count_: return null
      page_ = (client_ as api.ArtemisClient).channel_receive_page handle_ --page=spare_
      spare_ = null
      cursor_ = 18  // TODO(kasper): Avoid hardcoding this!
      count_ = 0
      acknowledged_ = 0
    next := receive_next_
    if next: count_++
    print "received: $next -- $count_"
    return next

  acknowledge n/int=1 -> none:
    acknowledged := acknowledged_ + n
    count := count_
    if acknowledged > count: throw "Bonkers!"
    acknowledged_ = acknowledged
    if cursor_ != 0 or acknowledged < count: return
    (client_ as api.ArtemisClient).channel_acknowledge handle_ 0 acknowledged
    spare_ = page_
    page_ = null

  receive_next_ -> ByteArray?:
    print "receive next from $cursor_ ($page_)"
    cursor := cursor_
    from := cursor
    page := page_
    acc := page ? page[cursor++] : 0xff
    if acc == 0xff:
      cursor_ = 0
      return null

    to := from
    bits := 6
    acc &= 0x3f
    while true:
      while bits < 8:
        if cursor >= page.size:
          cursor_ = 0
          return page[from..to]
        next := page[cursor]
        if (next & 0x80) != 0:
          cursor_ = cursor
          print "updated cursor to $cursor"
          return page[from..to]
        acc |= (next << bits)
        bits += 7
        cursor++
      page[to++] = (acc & 0xff)
      acc >>= 8
      bits -= 8
