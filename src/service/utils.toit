// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import ..shared.server_config

decode_server_config key/string assets/Map -> ServerConfig?:
  broker_entry := assets.get key --if_present=: tison.decode it
  if not broker_entry: return null
  // We use the key as name for the broker configuration.
  return ServerConfig.from_json key broker_entry
      --der_deserializer=: assets.get it

deep_copy o/any -> any:
  if o is Map:
    return (o as Map).map: | _ value | deep_copy value
  else if o is List:
    return (o as List).map: deep_copy it
  else:
    return o
