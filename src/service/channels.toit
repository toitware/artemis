// Copyright (C) 2023 Toitware ApS. All rights reserved.

import system.services show ServiceResource
import system.storage

import .service show ArtemisServiceProvider
import .flashlog show FlashLog SN

class ChannelResource extends ServiceResource:
  topic/string
  region_/storage.Region? := ?
  log_/FlashLog? := ?

  constructor provider/ArtemisServiceProvider client/int --.topic:
    // TODO(kasper): Should we be reference counting this,
    // so we can have multiple resources opened on the same
    // region? Probably.
    region_ = storage.Region.open --flash "toit.io/channel/$topic"
        --capacity=32 * 1024
    log_ = FlashLog region_
    super provider client

  send bytes/ByteArray -> none:
    print "-- appending $bytes"
    log_.append bytes

  receive_page --page/ByteArray? -> ByteArray:
    page = page or (ByteArray log_.size_per_page_)
    log_.read_page page
    return page

  acknowledge sn/int count/int -> none:
    last := SN.next sn --increment=count
    log_.acknowledge last

  on_closed -> none:
    region := region_
    if not region: return
    region_ = null
    log_ = null
    region.close
