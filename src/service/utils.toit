// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison
import ..shared.server_config

decode_server_config key/string assets/Map -> ServerConfig?:
  broker_entry := assets.get key --if_present=: tison.decode it
  if not broker_entry: return null
  // We use the key as name for the broker configuration.
  return ServerConfig.from_json key broker_entry
      // TODO(florian): can we avoid to stringify the certificate?
      --certificate_text_provider=: (assets.get it).to_string
