// Copyright (C) 2023 Toitware ApS. All rights reserved.

/**
An event reported by a device.
*/
class Event:
  /** The time the event was received by the broker. */
  timestamp/Time

  /** The data that was sent by the device. */
  data/any

  constructor .timestamp .data:
