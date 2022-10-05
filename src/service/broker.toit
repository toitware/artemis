// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.tison

decode_broker key/string assets/Map -> Map?:
  device := assets.get key --if_present=: tison.decode it
  if not device: return null
  if supabase := device.get "supabase":
    certificate_name := supabase["certificate"]
    certificate := assets.get certificate_name
    // TODO(kasper): Fix x509 certificate parser to accept slices.
    if certificate is ByteArraySlice_: certificate = certificate.copy
    supabase["certificate"] = certificate
  return device
