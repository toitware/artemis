// Copyright (C) 2022 Toitware ApS. All rights reserved.

/**
Responsible for allowing the Artemis CLI to talk to Artemis services on devices.
*/
interface MediatorCli:
  // TODO(florian): we probably want to add a `connect` function to this interface.
  // At the moment we require the connection to be open when artemis receives the
  // mediator.

  /** Closes this mediator. */
  close -> none

  /** Whether this mediator is closed. */
  is_closed -> bool

  /**
  Invokes the $block with the current configuration (a Map) of $device_id and
    updates the device's configuration with the new map that is returned from the block.

  The $block is allowed to modify the given configuration but is still required
    to return it.
  */
  device_update_config --device_id/string [block] -> none

  /**
  Uploads an application image with the given $app_id so that a device can fetch it.

  There may be multiple images for the same $app_id, that differ in the $bits size.
    Generally $bits is either 32 or 64.
  */
  upload_image --app_id/string --bits/int content/ByteArray -> none

  /**
  Uploads a firmware with the given $firmware_id so that a device can fetch it.
  */
  upload_firmware --firmware_id/string chunks/List -> none

  /**
  Downloads a firmware chunk. Ugly interface.
  */
  download_firmware --id/string -> ByteArray
