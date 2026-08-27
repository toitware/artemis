// Copyright (C) 2022 Toitware ApS. All rights reserved.

import crypto.sha1
import encoding.base64 as base64-lib
import supabase
import tls

import .broker-config show BrokerConfig
import .scope show Scope

abstract class ServerConfig:
  name/string

  /**
  The $Scope this fleet uses when talking to the server.

  Null outside of fleet-file contexts (e.g., entries in the global CLI
    config don't carry a scope — scope is a fleet-level concept).
  */
  scope/Scope?

  cache-key_/string? := null
  ders-already-installed_/bool := false

  constructor.from-sub_ .name --.scope/Scope?=null:

  /**
  Creates a CLI server configuration from a JSON map.

  Calls the $der-deserializer to undo the deduplication operation of
    $to-json.
  */
  constructor.from-json name/string json-map/Map [--der-deserializer]:
    // This is a bit fishy, as the constructors can already to validity checks
    // before we have recovered the contents of fields that were deduplicated.
    config/ServerConfig := ?
    if json-map["type"] == "supabase":
      config = ServerConfigSupabase.from-json name json-map
          --der-deserializer=der-deserializer
    else if json-map["type"] == "toit-http":
      config = ServerConfigHttp.from-json name json-map
          --der-deserializer=der-deserializer
    else:
      throw "Unknown server type: $json-map"
    return config

  abstract type -> string

  /**
  Serializes this configuration to a JSON map.

  Uses the $der-serializer block to store larger certificates that
    should be deduplicated.
  The $der-serializer is called with a certificate DER, and must
    return a unique identifier for the certificate.

  If $base64 is true, then any DERs is base64-encoded without calling
    the $der-serializer.

  # Inheritance
  The returned map must include a field "type" with the value returned by
    $type.
  */
  abstract to-json [--der-serializer] --base64/bool=false -> Map

  /**
  Creates the broker configuration used by the Artemis service.
  */
  abstract to-broker-config -> BrokerConfig

  /**
  Serializes the broker configuration used by the Artemis service.

  See $to-json for a description of the $der-serializer block.
  */
  to-service-json [--der-serializer] --base64/bool=false -> Map:
    return to-broker-config.to-json
        --der-serializer=der-serializer
        --base64=base64

  /**
  A list of DER certificates that are required for this broker to work.
  */
  abstract root-certificate-ders -> List?

  /**
  Computes a unique key that can be used for caching.
  */
  abstract compute-cache-key_ -> string

  /**
  Returns a copy of this config with the non-null fields overridden.

  Used to attach a fleet's scope to a $ServerConfig that was loaded from
    the global CLI config, which never carries a scope.
  */
  abstract with --scope/Scope?=null -> ServerConfig

  /**
  A unique key that can be used for caching.
  */
  cache-key -> string:
    if not cache-key_:
      cache-key_ = base64-lib.encode --url-mode (sha1.sha1 compute-cache-key_)
    return cache-key_

  /**
  Installs the DER certificates if they exist and if they aren't already installed.
  */
  install-root-certificates -> none:
    if ders-already-installed_: return
    ders-already-installed_ = true
    ders := root-certificate-ders
    if ders:
      ders.do: | der/ByteArray |
        certificate := tls.RootCertificate der
        certificate.install

class ServerConfigSupabase extends ServerConfig implements supabase.ServerConfig:
  url/string
  anon/string
  root-certificate-ders/List?
  poll-interval/Duration := ?

  uri -> string: return url

  constructor.from-json name/string json/Map [--der-deserializer]:
    roots := decode-root-certificates_ json --der-deserializer=der-deserializer
    url/string? := json.get "url"
    if not url:
      use-tls := json.get "use_tls"
      if use-tls == null: use-tls = json.contains "root_certificate_name"
      scheme := use-tls or roots ? "https" : "http"
      url = "$scheme://$(json["host"])"
    scope-value := json.get "scope"
    scope/Scope? := scope-value and (Scope scope-value)
    return ServerConfigSupabase name
        --url=url
        --anon=json["anon"]
        --root-certificate-ders=roots
        --poll-interval=Duration --us=json["poll_interval"]
        --scope=scope

  constructor name/string
      --url/string
      --.anon
      --.root-certificate-ders=null
      --.poll-interval=BrokerConfig.DEFAULT-POLL-INTERVAL
      --scope/Scope?=null:
    this.url = without-trailing-slash_ url
    super.from-sub_ name --scope=scope

  operator== other:
    if other is not ServerConfigSupabase: return false
    return url == other.url and anon == other.anon and
        root-certificate-ders == other.root-certificate-ders

  type -> string: return "supabase"

  to-json [--der-serializer] --base64/bool=false -> Map:
    result := {
      "type": type,
      "url": url,
      "anon": anon,
      "poll_interval": poll-interval.in-us,
    }
    add-root-certificates_ result root-certificate-ders
        --der-serializer=der-serializer
        --base64=base64
    if scope: result["scope"] = scope.to-json
    return result

  to-broker-config -> BrokerConfig:
    base-url := without-trailing-slash_ url
    return BrokerConfig
        --fetch-goal-state-url-template="$base-url/functions/v1/device/{device-id}/goal"
        --fetch-image-url-template="$base-url/storage/v1/object/public/toit-artemis-assets/{organization-id}/images/{id}.{word-size}"
        --fetch-firmware-url-template="$base-url/storage/v1/object/public/toit-artemis-assets/{organization-id}/firmware/{id}"
        --report-state-url-template="$base-url/functions/v1/device/{device-id}/state"
        --report-event-url-template="$base-url/functions/v1/device/{device-id}/events"
        --root-certificate-ders=root-certificate-ders
        --headers=null
        --poll-interval=poll-interval

  compute-cache-key_ -> string: return url

  with -> ServerConfigSupabase
      --url/string?=null
      --scope/Scope?=null:
    return ServerConfigSupabase
        name
        --url=(url or this.url)
        --anon=anon
        --root-certificate-ders=root-certificate-ders
        --poll-interval=poll-interval
        --scope=(scope or this.scope)

/**
A CLI configuration for an HTTP-based server.

Device configurations generated from it contain operation-specific URL
  templates instead.
*/
class ServerConfigHttp extends ServerConfig:
  url/string
  root-certificate-ders/List?
  device-headers/Map?
  admin-headers/Map?
  poll-interval/Duration := ?

  constructor.from-json name/string config/Map [--der-deserializer]:
    roots := decode-root-certificates_ config --der-deserializer=der-deserializer
    url/string? := config.get "url"
    if not url:
      use-tls := config.get "use_tls"
      if use-tls == null: use-tls = config.contains "root_certificate_names"
      scheme := use-tls or roots ? "https" : "http"
      port := config.get "port"
      port-suffix := port ? ":$port" : ""
      url = "$scheme://$(config["host"])$port-suffix$(config["path"])"
    scope-value := config.get "scope"
    scope/Scope? := scope-value and (Scope scope-value)
    return ServerConfigHttp name
        --url=url
        --root-certificate-ders=roots
        --device-headers=config.get "device_headers"
        --admin-headers=config.get "admin_headers"
        --poll-interval=Duration --us=config["poll_interval"]
        --scope=scope

  constructor name/string
      --url/string
      --.root-certificate-ders=null
      --.device-headers=null
      --.admin-headers=null
      --.poll-interval=BrokerConfig.DEFAULT-POLL-INTERVAL
      --scope/Scope?=null:
    this.url = without-trailing-slash_ url
    super.from-sub_ name --scope=scope

  operator== other:
    if other is not ServerConfigHttp: return false
    return url == other.url

  type -> string: return "toit-http"

  to-json [--der-serializer] --base64/bool=false -> Map:
    result := {
      "type": type,
      "url": url,
      "poll_interval": poll-interval.in-us,
    }
    add-root-certificates_ result root-certificate-ders
        --der-serializer=der-serializer
        --base64=base64
    if device-headers: result["device_headers"] = device-headers
    if admin-headers: result["admin_headers"] = admin-headers
    if scope: result["scope"] = scope.to-json
    return result

  to-broker-config -> BrokerConfig:
    base-url := without-trailing-slash_ url
    return BrokerConfig
        --fetch-goal-state-url-template="$base-url/device/{device-id}/goal"
        --fetch-image-url-template="$base-url/artifacts/{organization-id}/images/{id}.{word-size}"
        --fetch-firmware-url-template="$base-url/artifacts/{organization-id}/firmware/{id}"
        --report-state-url-template="$base-url/device/{device-id}/state"
        --report-event-url-template="$base-url/device/{device-id}/events"
        --root-certificate-ders=root-certificate-ders
        --headers=device-headers
        --poll-interval=poll-interval

  compute-cache-key_ -> string: return url

  with -> ServerConfigHttp
      --scope/Scope?=null:
    return ServerConfigHttp
        name
        --url=url
        --root-certificate-ders=root-certificate-ders
        --device-headers=device-headers
        --admin-headers=admin-headers
        --poll-interval=poll-interval
        --scope=(scope or this.scope)

decode-root-certificates_ config/Map [--der-deserializer] -> List?:
  if encoded-roots := config.get "root_certificate_ders64":
    return encoded-roots.map: base64-lib.decode it
  if root-ids := config.get "root_certificate_ders":
    return root-ids.map: der-deserializer.call it

  // Compatibility with the old singular Supabase certificate fields.
  if encoded-root := config.get "root_certificate_der64":
    return [base64-lib.decode encoded-root]
  if root-id := config.get "root_certificate_der_id":
    return [der-deserializer.call root-id]
  return null

add-root-certificates_ result/Map roots/List?
    --base64/bool
    [--der-serializer] -> none:
  if not roots: return
  if base64:
    result["root_certificate_ders64"] = roots.map: base64-lib.encode it
  else:
    result["root_certificate_ders"] = roots.map: der-serializer.call it

without-trailing-slash_ url/string -> string:
  return url.ends-with "/" ? url[..url.size - 1] : url
