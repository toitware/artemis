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
  cursor_/int := 0

  constructor.internal_ client/api.ArtemisClient handle/int --.topic:
    super client handle

  static open --topic/string -> Channel:
    client := artemis_client_
    if not client: throw "Artemis unavailable"
    handle := client.channel_open --topic=topic
    return Channel.internal_ client handle --topic=topic

  send bytes/ByteArray -> none:
    unreachable

  receive --wait/bool=false -> ByteArray?:
    next := receive_next_
    if next: return next

    // wait ... fill in more.

  receive_next_ -> ByteArray?:
    cursor := cursor_
    from := cursor
    page := page_
    acc := page ? page[cursor++] : 0xff

    // Done?
    if acc == 0xff:
      page_ = null
      return null

    to := from
    bits := 6
    acc &= 0x3f
    while true:
      while bits < 8:
        if cursor >= page.size:
          // Done. Avoid getting an out-of-bounds read
          // on the next call to $receive_next_ by
          // clearing out the page field.
          page_ = null
          return page[from..to]
        next := page[cursor]
        if (next & 0x80) != 0:
          cursor_ = cursor
          return page[from..to]
        acc |= (next << bits)
        bits += 7
        cursor++
      page[to++] = (acc & 0xff)
      acc >>= 8
      bits -= 8
