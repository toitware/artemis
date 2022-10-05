// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.file
import encoding.json

read_broker_from_files path/string -> Map:
  broker := json.decode (file.read_content path)
  supabase := broker["supabase"]
  certificate_name := supabase["certificate"]
  // PEM certificates need to be zero terminated. Ugh.
  certificate := (file.read_content "config/certificates/$certificate_name") + #[0]
  supabase["certificate"] = certificate
  return broker
