// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import ..shared.server-config

decode-server-config key/string assets/Map -> ServerConfig?:
  broker-entry := assets.get key --if-present=: tison.decode it
  if not broker-entry: return null
  // We use the key as name for the broker configuration.
  return ServerConfig.from-json key broker-entry
      --der-deserializer=: assets.get it

deep-copy o/any -> any:
  if o is Map:
    return (o as Map).map: | _ value | deep-copy value
  else if o is List:
    return (o as List).map: deep-copy it
  else:
    return o
