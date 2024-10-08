// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import uuid show Uuid

import ..artemis as artemis
import ..api as api

class Device implements artemis.Device:
  client_/api.ArtemisClient
  id/Uuid
  constructor client/api.ArtemisClient?:
    if not client: throw "Artemis unavailable"
    client_ = client
    id = Uuid client.device-id
