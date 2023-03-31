// Copyright (C) 2023 Toitware ApS. All rights reserved.

import system.services show ServiceResource
import system.storage

import .service show ArtemisServiceProvider

class ChannelResource extends ServiceResource:
  topic/string
  region_/storage.Region? := ?

  constructor provider/ArtemisServiceProvider client/int --.topic:
    // TODO(kasper): Should we be reference counting this, so
    // we can have multiple resources opened on the same
    // region? Probably.
    region_ = storage.Region.open --flash "toit.io/channel/$topic"
    super provider client

  on_closed -> none:
    region := region_
    if not region: return
    region_ = null
    region.close
