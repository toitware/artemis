// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services

import ..artemis as artemis
import ..api as api

class Controller extends services.ServiceResourceProxy:
  constructor client/api.ArtemisClient? --mode/int --force-recovery-contact/bool:
    if not client: throw "Artemis unavailable"
    handle := client.controller-open --mode=mode --force-recovery-contact=force-recovery-contact
    super client handle

  static run client/api.ArtemisClient? -> none
      --mode/int
      --force-recovery-contact/bool=false
      [block]:
    controller := Controller client --mode=mode --force-recovery-contact=force-recovery-contact
    try:
      block.call
    finally:
      // It is important that we give Artemis a chance to react to
      // the close event, even if we're out of time.
      critical-do --no-respect-deadline: controller.close
