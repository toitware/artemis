// Copyright (C) 2022 Toitware ApS. All rights reserved.

abstract class BrokerConfig:
  name/string
  config_/Map

  constructor.from_sub_ .name .config_:

  constructor name/string config/Map:
    if config["type"] == "supabase":
      return SupabaseBrokerConfig name config
    else if config["type"] == "mqtt":
      return MqttBrokerConfig name config
    else:
      throw "Unknown broker type: $config"

  /**
  Creates a new broker-config.
  Deserializes the serialized map, using the $certificate_deserializer to
    get the serialized certificate texts.

  The $serialized object is modified and stored internally. It must not be
    modified after calling this method.
  */
  constructor.deserialize name/string serialized/Map [certificate_deserializer]:
    // This is a bit fishy, as the constructors can already to validity checks
    // before we have recovered the content of fields that were deduplicated.
    config := BrokerConfig name serialized
    config.config_.map: | key value |
      if config.is_certificate_text_ key:
        certificate_deserializer.call value
      else:
        value
    return config

  /**
  Serializes this configuration to a map.

  Uses the $certificate_serializer block to store larger certificates that
    should be deduplicated.
  The $certificate_serializer is called with a certificate text, and must
    return a unique identifier for the certificate.
  */
  serialize [certificate_serializer] -> Map:
    result := config_.copy
    result.map: | key value |
      if is_certificate_text_ key:
        certificate_serializer.call value
      else:
        value
    return result

  abstract is_certificate_text_ field/string -> bool
  abstract fill_certificate_texts [certificate_getter] -> none

class SupabaseBrokerConfig extends BrokerConfig:
  constructor name/string config/Map:
    super.from_sub_ name config
    check_

  constructor name/string
      --host/string
      --anon/string
      --root_certificate_name/string?=null:
    config := {
      "type": "supabase",
      "host": host,
      "anon": anon,
    }
    if root_certificate_name:
      config["root_certificate_name"] = root_certificate_name
    return SupabaseBrokerConfig name config

  host -> string:
    return config_["host"]

  port -> int:
    return config_["port"]

  anon -> string:
    return config_["anon"]

  is_secured -> bool:
    return config_.contains "certificate_name" or config_.contains "certificate_text"

  /**
  The name of the root certificate.

  If both $certificate_text and $certificate_name are set, then $certificate_text is used.
  */
  certificate_name -> string?:
    return config_.get "certificate_name"

  /**
  The text (usually starting with "-----BEGIN CERTIFICATE-----") of the root certificate.

  On the devices, having the certificate_text is preferred, as it avoids having to
    store all the available certificates.
  */
  certificate_text -> string?:
    return config_.get "certificate_text"

  certificate_text= certificate_text/string:
    config_["certificate_text"] = certificate_text

  is_certificate_text_ field/string -> bool:
    return field == "certificate_text"

  fill_certificate_texts [certificate_getter] -> none:
    if certificate_name and not certificate_text:
      certificate_text = certificate_getter.call certificate_name

  check_:
    if not config_.contains "host": throw "Missing host"
    if not config_.contains "anon": throw "Missing anon"

class MqttBrokerConfig extends BrokerConfig:
  constructor name/string config/Map:
    super.from_sub_ name config

  constructor name/string
      --host/string
      --port/int
      --root_certificate_name/string?=null
      --client_certificate/string?=null
      --client_private_key/string?=null:
    config := {
      "type": "mqtt",
      "host": host,
      "port": port,
    }
    if root_certificate_name:
      config["root_certificate_name"] = root_certificate_name
    if client_certificate:
      config["client_certificate_text"] = client_certificate
    if client_private_key:
      config["client_private_key"] = client_private_key
    return MqttBrokerConfig name config

  host -> string:
    return config_["host"]

  port -> int:
    return config_["port"]

  is_secured -> bool:
    return config_.contains "root_certificate_name" or config_.contains "root_certificate_text"

  root_certificate_name -> string?:
    return config_.get "root_certificate_name"

  root_certificate_text -> string?:
    return config_.get "root_certificate_text"

  root_certificate_text= certificate_text/string:
    config_["root_certificate_text"] = certificate_text

  has_client_certificate -> bool:
    return config_.contains "client_certificate_text"

  client_certificate_text -> string?:
    return config_.get "client_certificate_text"

  client_private_key -> string?:
    return config_.get "client_private_key"

  is_certificate_text_ field/string -> bool:
    return field == "root_certificate_text" or field == "client_certificate_text"

  fill_certificate_texts [certificate_getter] -> none:
    if root_certificate_name and not root_certificate_text:
      root_certificate_text = certificate_getter.call root_certificate_name

  check_:
    if not config_.contains "host": throw "Missing host"
    if not config_.contains "port": throw "Missing port"
    if client_certificate_text and not client_private_key:
      throw "Missing client_private_key"

/**
An MQTT broker config that has a lambda to create the transport.

In this configuration no other fields (like $host) can be used.
*/
class CreateTransportMqttBrokerConfig extends MqttBrokerConfig:
  create_transport_/Lambda

  constructor name/string create_transport/Lambda:
    create_transport_ = create_transport
    super name {:}

  is_secured -> bool:
    return false

  create_transport:
    return create_transport_.call

  check_:
    // Don't do any checks.
