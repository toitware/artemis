// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.file
import encoding.json
import .config

read_broker_from_files path/string -> Map:
  broker := json.decode (file.read_content path)
  supabase := broker["supabase"]
  certificate_name := supabase["certificate"]
  // PEM certificates need to be zero terminated. Ugh.
  certificate := (file.read_content "config/certificates/$certificate_name") + #[0]
  supabase["certificate"] = certificate
  return broker

get_broker config/Config broker_name/string -> Map:
  brokers := config.get "brokers"
  if not brokers: throw "No brokers configured"
  broker_config/Map? := brokers.get broker_name
  if not broker_config: throw "No broker named $broker_name"
  result := broker_config.copy
  if supabase := result.get "supabase":
    if certificate_name := supabase.get "certificate":
      // Replace the certificate name with its content.
      supabase["certificate"] = get_certificate_ config certificate_name
  return result

get_certificate_ config/Config certificate_name/string -> ByteArray:
  assets := config.get "assets"
  if not assets: throw "No assets configured"
  certificates := assets.get "certificates"
  if not certificates: throw "No certificates configured"
  certificate := certificates.get certificate_name
  if not certificate: throw "No certificate named $certificate_name"
  // PEM certificates need to be zero terminated. Ugh.
  return certificate.to_byte_array + #[0]
