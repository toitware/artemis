// Copyright (C) 2022 Toitware ApS. All rights reserved.

import supabase

abstract class ServerConfig:
  name/string

  constructor.from_sub_ .name:

  /**
  Creates a new broker-config from a JSON map.

  Calls the $certificate_text_provider to undo the deduplication operation of
    $to_json.
  */
  constructor.from_json name/string json_map/Map [--certificate_text_provider]:
    // This is a bit fishy, as the constructors can already to validity checks
    // before we have recovered the content of fields that were deduplicated.
    config/ServerConfig := ?
    if json_map["type"] == "supabase":
      config = ServerConfigSupabase.from_json name json_map
          --certificate_text_provider=certificate_text_provider
    else if json_map["type"] == "mqtt":
      config = ServerConfigMqtt.from_json name json_map
          --certificate_text_provider=certificate_text_provider
    else if json_map["type"] == "toit-http":
      config = ServerConfigHttpToit.from_json name json_map
    else:
      throw "Unknown broker type: $json_map"
    return config

  abstract type -> string

  /**
  Fills the certificate texts for all certificates where we only have the name.
  */
  abstract fill_certificate_texts [certificate_getter] -> none

  /**
  Serializes this configuration to a JSON map.

  Uses the $certificate_deduplicator block to store larger certificates that
    should be deduplicated.
  The $certificate_deduplicator is called with a certificate text, and must
    return a unique identifier for the certificate.

  # Inheritance
  The returned map must include a field "type" with the value returned by
    $type.
  */
  abstract to_json [--certificate_deduplicator] -> Map

class ServerConfigSupabase extends ServerConfig implements supabase.ServerConfig:
  static DEFAULT_POLL_INTERVAL ::= Duration --s=20

  host/string
  anon/string
  poll_interval/Duration := ?

  /**
  The name of the root certificate.

  If both $root_certificate_text and $root_certificate_name are set, then $root_certificate_text is used.
  */
  root_certificate_name/string?
  /**
  The text (usually starting with "-----BEGIN CERTIFICATE-----") of the root certificate.

  On the devices not all certificates are available and inlining the required
    texts reduces the size that is needed for certificates.
  */
  root_certificate_text/string? := ?

  constructor.from_json name/string json/Map [--certificate_text_provider]:
    root_text := json.get "root_certificate_text"
    if root_text: root_text = certificate_text_provider.call root_text
    return ServerConfigSupabase name
        --host=json["host"]
        --anon=json["anon"]
        --poll_interval=Duration --us=json["poll_interval"]
        --root_certificate_name=json.get "root_certificate_name"
        --root_certificate_text=root_text

  constructor name/string
      --.host
      --.anon
      --.root_certificate_name=null
      --.root_certificate_text=null
      --.poll_interval=DEFAULT_POLL_INTERVAL:
    super.from_sub_ name

  type -> string: return "supabase"

  is_secured -> bool:
    return root_certificate_name != null or root_certificate_text != null

  /**
  Fills the certificate text for the root certificate if there
    is a certificate name and no certificate text.
  */
  fill_certificate_texts [certificate_getter] -> none:
    if root_certificate_name and not root_certificate_text:
      root_certificate_text = certificate_getter.call root_certificate_name

  to_json  [--certificate_deduplicator] -> Map:
    result := {
      "type": type,
      "host": host,
      "anon": anon,
      "poll_interval": poll_interval.in_us,
    }
    if root_certificate_name:
      result["root_certificate_name"] = root_certificate_name
    if root_certificate_text:
      result["root_certificate_text"] = certificate_deduplicator.call root_certificate_text
    return result

class ServerConfigMqtt extends ServerConfig:
  host/string
  port/int

  root_certificate_name/string?
  root_certificate_text/string? := ?
  client_certificate_text/string?
  client_private_key/string?

  constructor.from_json name/string config/Map [--certificate_text_provider]:
    root_text := config.get "root_certificate_text"
    if root_text: root_text = certificate_text_provider.call root_text
    client_text := config.get "client_certificate_text"
    if client_text: client_text = certificate_text_provider.call client_text
    return ServerConfigMqtt name
        --host=config["host"]
        --port=config["port"]
        --root_certificate_name=config.get "root_certificate_name"
        --root_certificate_text=root_text
        --client_certificate_text=client_text
        --client_private_key=config.get "client_private_key"

  constructor name/string
      --.host
      --.port
      --.root_certificate_name=null
      --.root_certificate_text=null
      --.client_certificate_text=null
      --.client_private_key=null:
    if client_certificate_text and not client_private_key:
      throw "Missing client_private_key"
    super.from_sub_ name

  type -> string: return "mqtt"

  is_secured -> bool:
    return root_certificate_name != null or root_certificate_text != null

  has_client_certificate -> bool:
    return client_certificate_text != null

  to_json [--certificate_deduplicator] -> Map:
    result := {
      "type": type,
      "host": host,
      "port": port,
    }
    if root_certificate_name:
      result["root_certificate_name"] = root_certificate_name
    if root_certificate_text:
      result["root_certificate_text"] = certificate_deduplicator.call root_certificate_text
    if client_certificate_text:
      result["client_certificate_text"] = certificate_deduplicator.call client_certificate_text
    if client_private_key:
      result["client_private_key"] = client_private_key
    return result

  fill_certificate_texts [certificate_getter] -> none:
    if root_certificate_name and not root_certificate_text:
      root_certificate_text = certificate_getter.call root_certificate_name

/**
A broker configuration for an HTTP-based broker.

This broker uses the light-weight unsecured protocol we use internally.
*/
class ServerConfigHttpToit extends ServerConfig:
  host/string
  port/int

  constructor.from_json name/string config/Map:
    return ServerConfigHttpToit name
        --host=config["host"]
        --port=config["port"]

  constructor name/string
      --.host/string
      --.port/int:
    super.from_sub_ name

  type -> string: return "toit-http"

  to_json [--certificate_deduplicator] -> Map:
    return {
      "type": type,
      "host": host,
      "port": port,
    }

  fill_certificate_texts [certificate_getter] -> none:
