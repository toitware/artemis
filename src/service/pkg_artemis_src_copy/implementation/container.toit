// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import ..artemis as artemis
import ..api as api

class ContainerCurrent implements artemis.Container:
  client_/api.ArtemisClient
  constructor client/api.ArtemisClient?:
    if not client: throw "Artemis unavailable"
    client_ = client

  restart --delay/Duration?=null -> none:
    wakeup-us := delay and Time.monotonic-us + delay.in-us
    client_.container-current-restart --wakeup-us=wakeup-us
    // The container is restarted, so we don't not
    // return here.
    unreachable
