// Copyright (C) 2022 Toitware ApS. All rights reserved.

import crypto.md5
import encoding.ubjson
import encoding.base64
import supabase

abstract class ServerConfig:
  name/string

  cache-key_/string? := null

  constructor.from-sub_ .name:

  /**
  Creates a new broker-config from a JSON map.

  Calls the $der-deserializer to undo the deduplication operation of
    $to-json.
  */
  constructor.from-json name/string json-map/Map [--der-deserializer]:
    // This is a bit fishy, as the constructors can already to validity checks
    // before we have recovered the content of fields that were deduplicated.
    config/ServerConfig := ?
    if json-map["type"] == "supabase":
      config = ServerConfigSupabase.from-json name json-map
          --der-deserializer=der-deserializer
    else if json-map["type"] == "toit-http":
      config = ServerConfigHttp.from-json name json-map
    else:
      throw "Unknown broker type: $json-map"
    return config

  abstract type -> string

  /**
  Fills the certificate DERs for all certificates where we only have the name.
  */
  abstract fill-certificate-ders [certificate-getter] -> none

  /**
  Serializes this configuration to a JSON map.

  Uses the $der-serializer block to store larger certificates that
    should be deduplicated.
  The $der-serializer is called with a certificate DER, and must
    return a unique identifier for the certificate.

  # Inheritance
  The returned map must include a field "type" with the value returned by
    $type.
  */
  abstract to-json [--der-serializer] -> Map

  /**
  Serializes this configuration to a JSON map that can be used on the device.

  See $to-json for a description of the $der-serializer block.
  */
  abstract to-service-json [--der-serializer] -> Map

  /**
  A unique key that can be used for caching.
  */
  cache-key -> string:
    if not cache-key_:
      hash := md5.md5 (ubjson.encode (to-json --der-serializer=: it))
      cache-key_ = "$name-$(base64.encode hash)"
    return cache-key_

class ServerConfigSupabase extends ServerConfig implements supabase.ServerConfig:
  static DEFAULT-POLL-INTERVAL ::= Duration --s=20

  host/string
  anon/string
  poll-interval/Duration := ?

  /**
  The name of the root certificate.

  If both $root-certificate-der and $root-certificate-name are set, then
    $root-certificate-der is used.
  */
  root-certificate-name/string?
  /**
  The DER binary of the root certificate.

  On the devices not all certificates are available and inlining the required
    binaries reduces the size that is needed for certificates.
  */
  root-certificate-der/ByteArray? := ?

  constructor.from-json name/string json/Map [--der-deserializer]:
    root-der-id := json.get "root_certificate_der_id"
    root-der/ByteArray? := root-der-id and (der-deserializer.call root-der-id)
    return ServerConfigSupabase name
        --host=json["host"]
        --anon=json["anon"]
        --poll-interval=Duration --us=json["poll_interval"]
        --root-certificate-name=json.get "root_certificate_name"
        --root-certificate-der=root-der

  constructor name/string
      --.host
      --.anon
      --.root-certificate-name=null
      --.root-certificate-der=null
      --.poll-interval=DEFAULT-POLL-INTERVAL:
    super.from-sub_ name

  /**
  Compares this instance to $other.
  Does not take the $poll-interval into account.
  */
  operator== other:
    if other is not ServerConfigSupabase: return false
    return host == other.host and anon == other.anon and
        root-certificate-name == other.root-certificate-name and
        root-certificate-der == other.root-certificate-der

  type -> string: return "supabase"

  is-secured -> bool:
    return root-certificate-name != null or root-certificate-der != null

  /**
  Fills the certificate text for the root certificate if there
    is a certificate name and no certificate text.
  */
  fill-certificate-ders [certificate-getter] -> none:
    if root-certificate-name and not root-certificate-der:
      root-certificate-der = certificate-getter.call root-certificate-name

  to-json  [--der-serializer] -> Map:
    result := {
      "type": type,
      "host": host,
      "anon": anon,
      "poll_interval": poll-interval.in-us,
    }
    if root-certificate-name:
      result["root_certificate_name"] = root-certificate-name
    if root-certificate-der:
      result["root_certificate_der_id"] = der-serializer.call root-certificate-der
    return result

  to-service-json [--der-serializer] -> Map:
    return to-json --der-serializer=der-serializer

/**
A broker configuration for an HTTP-based broker.

This broker uses the light-weight unsecured protocol we use internally.
*/
class ServerConfigHttp extends ServerConfig:
  static DEFAULT-POLL-INTERVAL ::= Duration --s=20

  host/string
  port/int?
  path/string
  root-certificate-names/List?
  root-certificate-ders/List? := ?
  device-headers/Map?
  admin-headers/Map?
  poll-interval/Duration := ?

  constructor.from-json name/string config/Map:
    if config.get "root_certificate_ders":
      throw "json config for http broker must not contain root_certificate_ders"
    return ServerConfigHttp name
        --host=config["host"]
        --port=config.get "port"
        --path=config["path"]
        --root-certificate-names=config.get "root_certificate_names"
        --root-certificate-ders=null
        --device-headers=config.get "device_headers"
        --admin-headers=config.get "admin_headers"
        --poll-interval=Duration --us=config["poll_interval"]

  constructor name/string
      --.host
      --.port
      --.path
      --.root-certificate-names
      --.root-certificate-ders
      --.device-headers
      --.admin-headers
      --.poll-interval=DEFAULT-POLL-INTERVAL:

    super.from-sub_ name

  operator== other:
    if other is not ServerConfigHttp: return false
    return host == other.host and port == other.port

  type -> string: return "toit-http"

  fill-certificate-ders [certificate-getter] -> none:
    if root-certificate-names and not root-certificate-ders:
      root-certificate-ders = root-certificate-names.map: certificate-getter.call it

  to-json [--der-serializer] -> Map:
    result := {
      "type": type,
      "host": host,
      "path": path,
      "poll_interval": poll-interval.in-us,
    }
    if port:
      result["port"] = port
    if root-certificate-names:
      result["root_certificate_names"] = root-certificate-names
    if root-certificate-ders:
      result["root_certificate_ders"] = root-certificate-ders.map: der-serializer.call it
    if device-headers:
      result["device_headers"] = device-headers
    if admin-headers:
      result["admin_headers"] = admin-headers
    return result

  to-service-json [--der-serializer] -> Map:
    result := to-json --der-serializer=der-serializer
    result.remove "admin_headers"
    return result
