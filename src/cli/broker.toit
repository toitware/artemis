// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.file
import encoding.json
import .config
import ..shared.broker_config
import .brokers.mqtt.base
import .brokers.postgrest.supabase
import .brokers.http.base
import certificate_roots
import crypto.sha256
import encoding.base64

create_broker broker_config/BrokerConfig -> BrokerCli:
  if broker_config is BrokerConfigSupabase:
    return create_broker_cli_supabase (broker_config as BrokerConfigSupabase)
  if broker_config is BrokerConfigMqtt:
    return create_broker_cli_mqtt (broker_config as BrokerConfigMqtt)
  if broker_config is BrokerConfigHttpToit:
    return create_broker_cli_http_toit (broker_config as BrokerConfigHttpToit)
  throw "Unknown broker type"

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

get_certificate_ config/Config certificate_name/string -> ByteArray:
  assets := config.get "assets"
  if not assets: throw "No assets configured"
  certificates := assets.get "certificates"
  if not certificates: throw "No certificates configured"
  certificate := certificates.get certificate_name
  if not certificate: throw "No certificate named $certificate_name"
  // PEM certificates need to be zero terminated. Ugh.
  return certificate.to_byte_array + #[0]

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

/**
Responsible for allowing the Artemis CLI to talk to Artemis services on devices.
*/
interface BrokerCli:
  // TODO(florian): we probably want to add a `connect` function to this interface.
  // At the moment we require the connection to be open when artemis receives the
  // broker.

  /** Closes this broker. */
  close -> none

  /** Whether this broker is closed. */
  is_closed -> bool

  /**
  A unique ID of the broker that can be used for caching.
  May contain "/", in which case the cache will use subdirectories.
  */
  id -> string

  /**
  Invokes the $block with the current configuration (a Map) of $device_id and
    updates the device's configuration with the new map that is returned from the block.

  The $block is allowed to modify the given configuration but is still required
    to return it.
  */
  device_update_config --device_id/string [block] -> none

  /**
  Uploads an application image with the given $app_id so that a device can fetch it.

  There may be multiple images for the same $app_id, that differ in the $bits size.
    Generally $bits is either 32 or 64.
  */
  upload_image --app_id/string --bits/int content/ByteArray -> none

  /**
  Uploads a firmware with the given $firmware_id so that a device can fetch it.

  The $chunks are a list of byte arrays.
  */
  upload_firmware --firmware_id/string chunks/List -> none

  /**
  Downloads a firmware chunk. Ugly interface.
  */
  download_firmware --id/string -> ByteArray
