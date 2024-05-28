// Copyright (C) 2024 Toitware ApS. All rights reserved.

import watchdog.provider as watchdog

/**
A system watchdog that ignores all calls to it.
*/
class NullWatchdog implements watchdog.SystemWatchdog:
  start --ms/int:
  feed -> none:
  stop -> none:
  reboot -> none:

