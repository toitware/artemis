// Copyright (C) 2023 Toitware ApS. All rights reserved.

import system.services show ServiceResource ServiceProvider
import system.storage

import .flashlog show FlashLog SN

flashlogs_ ::= {:}
readers_ ::= {}

class ChannelResource extends ServiceResource:
  topic/string
  read/bool
  log_/FlashLog? := ?

  constructor provider/ServiceProvider client/int --.topic --.read:
    if read:
      if readers_.contains topic: throw "ALREADY_IN_USE"
      readers_.add topic
    log_ = flashlogs_.get topic --init=:
      path := "toit.io/channel/$topic"
      capacity := 32 * 1024
      FlashLog (storage.Region.open --flash path --capacity=capacity)
    log_.acquire
    super provider client

  send bytes/ByteArray -> none:
    log_.append bytes

  receive_page --peek/int --buffer/ByteArray? -> List:
    buffer = buffer or (ByteArray log_.size_per_page_)
    return log_.read_page buffer --peek=peek

  acknowledge sn/int count/int -> none:
    if count < 1: throw "Bad Argument"
    log_.acknowledge (SN.previous (SN.next sn --increment=count))

  on_closed -> none:
    log := log_
    if not log: return
    log_ = null
    if read: readers_.remove topic
    if log.release == 0: flashlogs_.remove topic
