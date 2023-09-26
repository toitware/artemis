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
    // The container is restarted, so we don't return here.
    unreachable

  trigger -> artemis.Trigger?:
    encoded-trigger := client_.container-current-trigger
    return artemis.Trigger.decode encoded-trigger

  triggers -> List:
    encoded-triggers := client_.container-current-triggers
    return encoded-triggers.map: artemis.Trigger.decode it

  set-next-start-triggers triggers/List? -> none:
    encoded-triggers := triggers
        ? triggers.map: | trigger/artemis.Trigger | trigger.encode
        : null
    client_.container-current-set-triggers encoded-triggers
