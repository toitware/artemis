// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .config
import ..shared.broker_config
import certificate_roots
import crypto.sha256
import encoding.base64

get_broker_from_config config/Config broker_name/string -> BrokerConfig:
  brokers := config.get "brokers"
  if not brokers: throw "No brokers configured"
  json_map := brokers.get broker_name
  if not json_map: throw "No broker named $broker_name"

  // Certificates weren't deduplicated. The block just returns 'it'.
  return BrokerConfig.from_json broker_name json_map --certificate_text_provider=: it

add_broker_to_config config/Config broker_config/BrokerConfig:
  if not config.contains "brokers":
    config["brokers"] = {:}
  brokers := config.get "brokers"

  // No need to deduplicate certificates. The block just returns 'it'.
  json := broker_config.to_json --certificate_deduplicator=: it
  brokers[broker_config.name] = json

/**
Serializes a certificate to a string.
Deduplicates them in the process.
*/
deduplicate_certificate certificate_string/string deduplicated_certificates/Map -> string:
  sha := sha256.Sha256
  sha.add certificate_string
  certificate_key := "certificate-$(base64.encode sha.get[0..8])"
  deduplicated_certificates[certificate_key] = certificate_string
  return certificate_key

broker_config_to_service_json broker_config/BrokerConfig deduplicated_certificates/Map -> any:
  broker_config.fill_certificate_texts: certificate_roots.MAP[it]
  return broker_config.to_json --certificate_deduplicator=:
    deduplicate_certificate it deduplicated_certificates
