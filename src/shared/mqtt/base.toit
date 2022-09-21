// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ..device

topic_config_for_ device_id/string -> string:
  return "toit/devices/$device_id/config"

topic_lock_for_ device_id/string -> string:
  config_topic := topic_config_for_ device_id
  return "$config_topic/writer"

topic_revision_for_ device_id/string -> string:
  config_topic := topic_config_for_ device_id
  return "$config_topic/revision"

topic_presence_for_ device_id/string -> string:
  return "toit/devices/presence/$device_id"

class DeviceMqtt implements Device:
  name/string
  topic_config/string
  topic_lock/string
  topic_revision/string
  topic_presence/string

  constructor .name:
    config ::= topic_config_for_ name
    topic_config = config
    topic_lock = topic_lock_for_ name
    topic_revision = topic_revision_for_ name
    topic_presence = topic_presence_for_ name
