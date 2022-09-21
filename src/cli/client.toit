// Copyright (C) 2022 Toitware ApS. All rights reserved.

import ..shared.device

abstract class Client:
  abstract device -> Device

  /**
  Gets current config for the specified $device.
  Calls the $block with the current config, and gets a new config back.
  Sends the new config to the device.
  */
  abstract update_config [block] -> none

  // Resource upload helpers.
  abstract upload_image id/string --bits/int content/ByteArray -> none
  abstract upload_firmware id/string content/ByteArray -> none

  // TODO(kasper): These are pretty MQTT specific at the moment.
  abstract print_status -> none
  abstract watch_presence -> none
