// Copyright (C) 2023 Toitware ApS. All rights reserved.

import system.services show ServiceResource
import .service show ArtemisServiceProvider

class ChannelResource extends ServiceResource:
  topic/string
  constructor provider/ArtemisServiceProvider client/int --.topic:
    super provider client

  on_closed -> none:
    // Do nothing.
