// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import ..shared.broker-config show BrokerConfig

decode-broker-config key/string assets/Map -> BrokerConfig?:
  broker-entry := assets.get key --if-present=: tison.decode it
  if not broker-entry: return null
  return BrokerConfig.from-json broker-entry --der-deserializer=: assets.get it

deep-copy o/any -> any:
  if o is Map:
    return (o as Map).map: | _ value | deep-copy value
  else if o is List:
    return (o as List).map: deep-copy it
  else:
    return o
