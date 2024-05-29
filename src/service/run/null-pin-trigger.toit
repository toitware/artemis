// Copyright (C) 2024 Toitware ApS. All rights reserved.

import ..pin-trigger

/**
A pin-trigger manager that does nothing.
*/
class NullPinTriggerManager implements PinTriggerManager:
  start jobs/List --scheduler --logger -> none:
  update-job job -> none:
  rearm-job job -> none:
  prepare-deep-sleep jobs -> none:
