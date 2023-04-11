// Copyright (C) 2023 Toitware ApS. All rights reserved.

import system.services show ServiceResource ServiceProvider
import system.storage

import .flashlog show FlashLog SN

class ChannelResource extends ServiceResource:
  topic/string
  region_/storage.Region? := ?
  log_/FlashLog? := ?

  constructor provider/ServiceProvider client/int --.topic:
    // TODO(kasper): Stop always resetting.
    storage.Region.delete --flash "toit.io/channel/$topic"
    // TODO(kasper): Should we be reference counting this,
    // so we can have multiple resources opened on the same
    // region? Probably not.
    region_ = storage.Region.open --flash "toit.io/channel/$topic"
        --capacity=32 * 1024
    log_ = FlashLog region_
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
    region := region_
    if not region: return
    region_ = null
    log_ = null
    region.close
