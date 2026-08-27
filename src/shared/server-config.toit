// Copyright (C) 2022 Toitware ApS. All rights reserved.

import crypto.sha1
import encoding.base64 as base64-lib
import supabase
import tls
import uuid show Uuid

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
  Creates a new broker-config from a JSON map.

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
    else if json-map["type"] == "http-templates":
      config = ServerConfigHttpTemplates.from-json name json-map
          --der-deserializer=der-deserializer
    else:
      throw "Unknown broker type: $json-map"
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
  Serializes this configuration to a JSON map that can be used on the device.

  See $to-json for a description of the $der-serializer block.
  */
  abstract to-service-json [--der-serializer] --base64/bool=false -> Map

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
  static DEFAULT-POLL-INTERVAL ::= Duration --s=20

  host/string
  anon/string
  poll-interval/Duration := ?

  uri -> string:
    if use-tls or root-certificate-der:
      return "https://$host"
    return "http://$host"

  /**
  Whether to use TLS/HTTPS for the connection.
  */
  use-tls/bool
  /**
  The DER binary of the root certificate.

  On the devices not all certificates are available and inlining the required
    binaries reduces the size that is needed for certificates.
  */
  root-certificate-der/ByteArray? := ?

  constructor.from-json name/string json/Map [--der-deserializer]:
    root-der-base64/string? := json.get "root_certificate_der64"
    root-der/ByteArray? := root-der-base64 and (base64-lib.decode root-der-base64)
    if not root-der:
      root-der-id := json.get "root_certificate_der_id"
      root-der = root-der-id and (der-deserializer.call root-der-id)
    use-tls := json.get "use_tls"
    if use-tls == null: use-tls = json.contains "root_certificate_name"
    scope-value := json.get "scope"
    scope/Scope? := scope-value and (Scope scope-value)
    return ServerConfigSupabase name
        --host=json["host"]
        --anon=json["anon"]
        --poll-interval=Duration --us=json["poll_interval"]
        --use-tls=use-tls
        --root-certificate-der=root-der
        --scope=scope

  constructor name/string
      --.host
      --.anon
      --.use-tls=true
      --.root-certificate-der=null
      --.poll-interval=DEFAULT-POLL-INTERVAL
      --scope/Scope?=null:
    super.from-sub_ name --scope=scope

  operator== other:
    if other is not ServerConfigSupabase: return false
    return host == other.host and anon == other.anon and
        use-tls == other.use-tls and
        root-certificate-der == other.root-certificate-der

  type -> string: return "supabase"

  is-secured -> bool:
    return use-tls or root-certificate-der != null

  to-json  [--der-serializer] --base64/bool=false -> Map:
    result := {
      "type": type,
      "host": host,
      "anon": anon,
      "poll_interval": poll-interval.in-us,
    }
    if use-tls:
      result["use_tls"] = use-tls
    if root-certificate-der:
      if base64:
        result["root_certificate_der64"] = base64-lib.encode root-certificate-der
      else:
        serialized := der-serializer.call root-certificate-der
        if serialized:
          result["root_certificate_der_id"] = serialized
    if scope:
      result["scope"] = scope.to-json
    return result

  to-service-json [--der-serializer] --base64/bool=false -> Map:
    scheme := use-tls ? "https" : "http"
    base-url := "$scheme://$host"
    template-config := ServerConfigHttpTemplates
        name
        --fetch-goal-state-url-template="$base-url/functions/v1/device/{device-id}/goal"
        --fetch-image-url-template="$base-url/storage/v1/object/public/toit-artemis-assets/{organization-id}/images/{id}.{word-size}"
        --fetch-firmware-url-template="$base-url/storage/v1/object/public/toit-artemis-assets/{organization-id}/firmware/{id}"
        --report-state-url-template="$base-url/functions/v1/device/{device-id}/state"
        --report-event-url-template="$base-url/functions/v1/device/{device-id}/events"
        --poll-interval=poll-interval
        --root-certificate-ders=root-certificate-der ? [root-certificate-der] : null
        --headers=null
    return template-config.to-service-json --der-serializer=der-serializer --base64=base64

  root-certificate-ders -> List?:
    return root-certificate-der and [root-certificate-der]

  compute-cache-key_ -> string:
    return host

  with -> ServerConfigSupabase
      --host/string?=null
      --scope/Scope?=null:
    return ServerConfigSupabase
        name
        --host=(host or this.host)
        --anon=anon
        --use-tls=use-tls
        --root-certificate-der=root-certificate-der
        --poll-interval=poll-interval
        --scope=(scope or this.scope)

/**
A broker configuration for an HTTP-based broker.

The CLI uses this configuration for the server's administrative interfaces.
Device configurations generated from it contain operation-specific URL
  templates instead.
*/
class ServerConfigHttp extends ServerConfig:
  static DEFAULT-POLL-INTERVAL ::= Duration --s=20

  host/string
  port/int?
  path/string
  use-tls/bool
  root-certificate-ders/List? := ?
  device-headers/Map?
  admin-headers/Map?
  poll-interval/Duration := ?

  constructor.from-json name/string config/Map [--der-deserializer]:
    root-certificates-ders/List? := null
    if encode-ders64 := config.get "root_certificate_ders64":
      root-certificates-ders = encode-ders64.map: base64-lib.decode it
    else if config.get "root_certificate_ders":
      root-certificates-ders = config["root_certificate_ders"].map: der-deserializer.call it
    use-tls := config.get "use_tls"
    if use-tls == null: use-tls = config.contains "root_certificate_names"
    scope-value := config.get "scope"
    scope/Scope? := scope-value and (Scope scope-value)
    return ServerConfigHttp name
        --host=config["host"]
        --port=config.get "port"
        --path=config["path"]
        --use-tls=use-tls
        --root-certificate-ders=root-certificates-ders
        --device-headers=config.get "device_headers"
        --admin-headers=config.get "admin_headers"
        --poll-interval=Duration --us=config["poll_interval"]
        --scope=scope

  constructor name/string
      --.host
      --.port
      --.path
      --.use-tls=false
      --.root-certificate-ders
      --.device-headers
      --.admin-headers
      --.poll-interval=DEFAULT-POLL-INTERVAL
      --scope/Scope?=null:

    super.from-sub_ name --scope=scope

  operator== other:
    if other is not ServerConfigHttp: return false
    return host == other.host and port == other.port

  type -> string: return "toit-http"

  to-json [--der-serializer] --base64/bool=false -> Map:
    result := {
      "type": type,
      "host": host,
      "path": path,
      "poll_interval": poll-interval.in-us,
    }
    if port:
      result["port"] = port
    if use-tls:
      result["use_tls"] = use-tls
    if root-certificate-ders:
      if base64:
        result["root_certificate_ders64"] = root-certificate-ders.map: base64-lib.encode it
      else:
        result["root_certificate_ders"] = root-certificate-ders.map: der-serializer.call it
    if device-headers:
      result["device_headers"] = device-headers
    if admin-headers:
      result["admin_headers"] = admin-headers
    if scope:
      result["scope"] = scope.to-json
    return result

  to-service-json [--der-serializer] --base64/bool=false -> Map:
    scheme := use-tls ? "https" : "http"
    port-suffix := port ? ":$port" : ""
    base-path := path
    if base-path.ends-with "/": base-path = base-path[..base-path.size - 1]
    base-url := "$scheme://$(host)$(port-suffix)$(base-path)"
    template-config := ServerConfigHttpTemplates
        name
        --fetch-goal-state-url-template="$base-url/device/{device-id}/goal"
        --fetch-image-url-template="$base-url/artifacts/{organization-id}/images/{id}.{word-size}"
        --fetch-firmware-url-template="$base-url/artifacts/{organization-id}/firmware/{id}"
        --report-state-url-template="$base-url/device/{device-id}/state"
        --report-event-url-template="$base-url/device/{device-id}/events"
        --poll-interval=poll-interval
        --root-certificate-ders=root-certificate-ders
        --headers=device-headers
    return template-config.to-json --der-serializer=der-serializer --base64=base64

  compute-cache-key_ -> string:
    return "$host:$port:$path"

  with -> ServerConfigHttp
      --scope/Scope?=null:
    return ServerConfigHttp
        name
        --host=host
        --port=port
        --path=path
        --use-tls=use-tls
        --root-certificate-ders=root-certificate-ders
        --device-headers=device-headers
        --admin-headers=admin-headers
        --poll-interval=poll-interval
        --scope=(scope or this.scope)

/**
An HTTP configuration with one URL template for each device broker operation.

All templates may use `{device-id}` and `{organization-id}`. The goal template
  may additionally use `{wait}`; the image template `{id}` and `{word-size}`;
  the firmware template `{id}` and `{offset}`; and the event template `{type}`.
*/
class ServerConfigHttpTemplates extends ServerConfig:
  static DEFAULT-POLL-INTERVAL ::= Duration --s=20

  fetch-goal-state-url-template/string
  fetch-image-url-template/string
  fetch-firmware-url-template/string
  report-state-url-template/string
  report-event-url-template/string
  root-certificate-ders/List? := ?
  headers/Map?
  poll-interval/Duration := ?

  constructor.from-json name/string config/Map [--der-deserializer]:
    root-certificates-ders/List? := null
    if encoded-ders64 := config.get "root_certificate_ders64":
      root-certificates-ders = encoded-ders64.map: base64-lib.decode it
    else if config.get "root_certificate_ders":
      root-certificates-ders = config["root_certificate_ders"].map: der-deserializer.call it
    scope-value := config.get "scope"
    scope/Scope? := scope-value and (Scope scope-value)
    return ServerConfigHttpTemplates name
        --fetch-goal-state-url-template=config["fetch_goal_state_url_template"]
        --fetch-image-url-template=config["fetch_image_url_template"]
        --fetch-firmware-url-template=config["fetch_firmware_url_template"]
        --report-state-url-template=config["report_state_url_template"]
        --report-event-url-template=config["report_event_url_template"]
        --root-certificate-ders=root-certificates-ders
        --headers=config.get "headers"
        --poll-interval=Duration --us=config["poll_interval"]
        --scope=scope

  constructor name/string
      --.fetch-goal-state-url-template
      --.fetch-image-url-template
      --.fetch-firmware-url-template
      --.report-state-url-template
      --.report-event-url-template
      --.root-certificate-ders
      --.headers
      --.poll-interval=DEFAULT-POLL-INTERVAL
      --scope/Scope?=null:
    super.from-sub_ name --scope=scope

  type -> string: return "http-templates"

  to-json [--der-serializer] --base64/bool=false -> Map:
    result := {
      "type": type,
      "fetch_goal_state_url_template": fetch-goal-state-url-template,
      "fetch_image_url_template": fetch-image-url-template,
      "fetch_firmware_url_template": fetch-firmware-url-template,
      "report_state_url_template": report-state-url-template,
      "report_event_url_template": report-event-url-template,
      "poll_interval": poll-interval.in-us,
    }
    if root-certificate-ders:
      if base64:
        result["root_certificate_ders64"] = root-certificate-ders.map: base64-lib.encode it
      else:
        result["root_certificate_ders"] = root-certificate-ders.map: der-serializer.call it
    if headers: result["headers"] = headers
    if scope: result["scope"] = scope.to-json
    return result

  to-service-json [--der-serializer] --base64/bool=false -> Map:
    result := to-json --der-serializer=der-serializer --base64=base64
    result.remove "scope"
    return result

  compute-cache-key_ -> string:
    return [
      fetch-goal-state-url-template,
      fetch-image-url-template,
      fetch-firmware-url-template,
      report-state-url-template,
      report-event-url-template,
    ].join ":"

  with -> ServerConfigHttpTemplates
      --scope/Scope?=null:
    return ServerConfigHttpTemplates
        name
        --fetch-goal-state-url-template=fetch-goal-state-url-template
        --fetch-image-url-template=fetch-image-url-template
        --fetch-firmware-url-template=fetch-firmware-url-template
        --report-state-url-template=report-state-url-template
        --report-event-url-template=report-event-url-template
        --root-certificate-ders=root-certificate-ders
        --headers=headers
        --poll-interval=poll-interval
        --scope=(scope or this.scope)
