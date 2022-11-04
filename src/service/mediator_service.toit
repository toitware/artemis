// Copyright (C) 2022 Toitware ApS. All rights reserved.

interface ResourceManager:
  fetch_image id/string [block] -> none
  fetch_firmware id/string --offset/int=0 [block] -> none
  fetch_resource path/string [block] -> none

  // TODO(kasper): Poor interface. We shouldn't need to pass
  // the device id here?
  report_status device_id/string status/Map -> none

interface EventHandler:
  handle_update_config new_config/Map resources/ResourceManager
  handle_nop

interface MediatorService:
  connect --device_id/string --callback/EventHandler [block]
  on_idle -> none
