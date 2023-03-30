// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import ..artemis as artemis
import ..api as api

class ContainerCurrent implements artemis.Container:
  service_/api.ArtemisService
  constructor:
    service := artemis.service_
    if not service: throw "Artemis unavailable"
    service_ = service

  restart --delay/Duration?=null -> none:
    service_.container_restart
        --delay_until_us=(delay and Time.monotonic_us + delay.in_us)
    // The container is restarted, so we don't not
    // return here.
    unreachable
