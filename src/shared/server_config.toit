// Copyright (C) 2022 Toitware ApS. All rights reserved.

import supabase

abstract class ServerConfig:
  name/string

  constructor.from_sub_ .name:

  /**
  Creates a new broker-config from a JSON map.

  Calls the $der_deserializer to undo the deduplication operation of
    $to_json.
  */
  constructor.from_json name/string json_map/Map [--der_deserializer]:
    // This is a bit fishy, as the constructors can already to validity checks
    // before we have recovered the content of fields that were deduplicated.
    config/ServerConfig := ?
    if json_map["type"] == "supabase":
      config = ServerConfigSupabase.from_json name json_map
          --der_deserializer=der_deserializer
    else if json_map["type"] == "toit-http":
      config = ServerConfigHttpToit.from_json name json_map
    else:
      throw "Unknown broker type: $json_map"
    return config

  abstract type -> string

  /**
  Fills the certificate DERs for all certificates where we only have the name.
  */
  abstract fill_certificate_ders [certificate_getter] -> none

  /**
  Serializes this configuration to a JSON map.

  Uses the $der_serializer block to store larger certificates that
    should be deduplicated.
  The $der_serializer is called with a certificate DER, and must
    return a unique identifier for the certificate.

  # Inheritance
  The returned map must include a field "type" with the value returned by
    $type.
  */
  abstract to_json [--der_serializer] -> Map

class ServerConfigSupabase extends ServerConfig implements supabase.ServerConfig:
  static DEFAULT_POLL_INTERVAL ::= Duration --s=20

  host/string
  anon/string
  poll_interval/Duration := ?

  /**
  The name of the root certificate.

  If both $root_certificate_der and $root_certificate_name are set, then
    $root_certificate_der is used.
  */
  root_certificate_name/string?
  /**
  The DER binary of the root certificate.

  On the devices not all certificates are available and inlining the required
    binaries reduces the size that is needed for certificates.
  */
  root_certificate_der/ByteArray? := ?

  constructor.from_json name/string json/Map [--der_deserializer]:
    root_der_id := json.get "root_certificate_der_id"
    root_der/ByteArray? := root_der_id and (der_deserializer.call root_der_id)
    return ServerConfigSupabase name
        --host=json["host"]
        --anon=json["anon"]
        --poll_interval=Duration --us=json["poll_interval"]
        --root_certificate_name=json.get "root_certificate_name"
        --root_certificate_der=root_der

  constructor name/string
      --.host
      --.anon
      --.root_certificate_name=null
      --.root_certificate_der=null
      --.poll_interval=DEFAULT_POLL_INTERVAL:
    super.from_sub_ name

  /**
  Compares this instance to $other.
  Does not take into account the $poll_interval.
  */
  operator== other:
    if other is not ServerConfigSupabase: return false
    return host == other.host and anon == other.anon and
        root_certificate_name == other.root_certificate_name and
        root_certificate_der == other.root_certificate_der

  type -> string: return "supabase"

  is_secured -> bool:
    return root_certificate_name != null or root_certificate_der != null

  /**
  Fills the certificate text for the root certificate if there
    is a certificate name and no certificate text.
  */
  fill_certificate_ders [certificate_getter] -> none:
    if root_certificate_name and not root_certificate_der:
      root_certificate_der = certificate_getter.call root_certificate_name

  to_json  [--der_serializer] -> Map:
    result := {
      "type": type,
      "host": host,
      "anon": anon,
      "poll_interval": poll_interval.in_us,
    }
    if root_certificate_name:
      result["root_certificate_name"] = root_certificate_name
    if root_certificate_der:
      result["root_certificate_der_id"] = der_serializer.call root_certificate_der
    return result

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

  operator== other:
    if other is not ServerConfigHttpToit: return false
    return host == other.host and port == other.port

  type -> string: return "toit-http"

  to_json [--der_serializer] -> Map:
    return {
      "type": type,
      "host": host,
      "port": port,
    }

  fill_certificate_ders [certificate_getter] -> none:
