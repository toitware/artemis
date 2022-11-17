// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .run.device as device  // For toitdoc.

/**
A representation of the device we are running on.

This class abstracts away the current configuration of the device.
*/
class Device:
  /**
  The hardware ID of the device.

  This ID was chosen during provisioning and is unique.
  */
  id/string
  config_/Map := ?

  /** See $firmware. */
  firmware_/string := ?
  /** See $max_offline. */
  max_offline_/Duration? := null

  constructor --.id --firmware/string:
    config_ = {
      "firmware": firmware,
    }
    firmware_ = firmware

  /**
  The max-offline as a Duration.
  The duration's value in seconds is also stored in the $config_ map, but might
    be temporarily different, if the max_offline has been changed, but the config
    hasn't been committed yet.

  In general, users should assume that these two values are in sync.
  */
  max_offline -> Duration?: return max_offline_
  max_offline= value/Duration?: max_offline_ = value

  /**
  The current firmware description of this device.

  The description is an opaque string (base64-encoded map of the firmware config with a checksum),
    that uniquely identifies the installed firmware. See $device.main for the encoding.

  The value might be different than the one in the $config, if the device
    hasn't installed the firmware yet, or hasn't rebooted yet.
  */
  firmware -> string: return firmware_
  firmware= new_firmware/string: firmware_ = new_firmware

  config -> Map:
    return config_

  config= new_config/Map:
    config_ = new_config
