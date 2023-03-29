// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services show ServiceSelector ServiceClient

interface ArtemisService:
  static SELECTOR ::= ServiceSelector
      --uuid="61d82c0b-7009-4e16-b248-324de4e25f9B"
      --major=0
      --minor=1

  version -> string
  static VERSION_INDEX /int ::= 0

class ArtemisClient extends ServiceClient
    implements ArtemisService:
  static SELECTOR ::= ArtemisService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  version -> string:
    return invoke_ ArtemisService.VERSION_INDEX null
