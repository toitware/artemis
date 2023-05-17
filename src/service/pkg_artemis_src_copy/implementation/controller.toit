// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services

import ..artemis as artemis
import ..api as api

class Controller extends services.ServiceResourceProxy:
  constructor --mode/int:
    client := artemis.artemis_client_
    if not client: throw "Artemis unavailable"
    handle := client.controller_open --mode=mode
    super client handle

  static run --mode/int [block] -> none:
    controller := Controller --mode=mode
    try:
      block.call
    finally:
      controller.close
