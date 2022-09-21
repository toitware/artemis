// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ..device

class DeviceMqtt implements Device:
  name/string
  topic_config/string
  topic_lock/string
  topic_revision/string
  topic_presence/string

  constructor .name:
    config ::= "toit/devices/$name/config"
    topic_config = config
    topic_lock = "$config/writer"
    topic_revision = "$config/revision"
    topic_presence = "toit/devices/presence/$name"
