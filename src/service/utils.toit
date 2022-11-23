// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import ..shared.broker_config

decode_broker_config key/string assets/Map -> BrokerConfig?:
  broker_entry := assets.get key --if_present=: tison.decode it
  if not broker_entry: return null
  // We use the key as name for the broker configuration.
  return BrokerConfig.from_json key broker_entry
      --certificate_text_provider=: assets.get it
