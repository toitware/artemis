// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .api as api

service_/api.ArtemisService? ::= (api.ArtemisClient).open
    --if_absent=: null

/**
Whether the Artemis service is available.
*/
available -> bool:
  return service_ != null

/**
Returns the version of the Artemis service.
*/
version -> string:
  service := service_
  if not service: throw "Artemis unavailable"
  return service.version

/**
...
*/
class Channel:
  topic/string
  constructor .topic:

  open topic/string -> Channel:
    unreachable

  close -> none:
    unreachable
