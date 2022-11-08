// Copyright (C) 2022 Toitware ApS. All rights reserved.

import host.file
import encoding.json
import .config

get_broker_config config/Config broker_name/string -> Map:
  brokers := config.get "brokers"
  if not brokers: throw "No brokers configured"
  broker_config/Map? := brokers.get broker_name
  if not broker_config: throw "No broker named $broker_name"
  result := broker_config.copy
  if supabase := result.get "supabase":
    if certificate_name := supabase.get "certificate":
      // Replace the certificate name with its content.
      supabase["certificate"] = get_certificate_ config certificate_name
  if mqtt := result.get "mqtt":
    if certificate_name := mqtt.get "root-certificate":
      // Replace the certificate name with its content.
      mqtt["root-certificate"] = get_certificate_ config certificate_name
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
