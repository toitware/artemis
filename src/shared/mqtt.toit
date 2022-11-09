// Copyright (C) 2022 Toitware ApS. All rights reserved.

import monitor
import mqtt
import mqtt.transport as mqtt
import net
import net.x509
import encoding.ubjson
import tls

/**
MQTT functionality.

This library contains functionality and constants that are shared between
  the CLI and the service.

Ideally, there is (or should be) a clear separation between the parts that
  are here because both sides agree on them, and the parts that are
  just generic and could live in their own package.
*/

create_transport network/net.Interface broker_config/Map -> mqtt.Transport:
  if broker_config.contains "create-transport":
    return broker_config["create-transport"].call network
  return create_transport network
      --host=broker_config["host"]
      --port=broker_config["port"]
      --root_certificate_text=broker_config.get "root-certificate"
      --client_certificate_text=broker_config.get "client-certificate"
      --client_key=broker_config.get "client-private-key"

create_transport network/net.Interface -> mqtt.Transport
    --host/string
    --port/int
    --root_certificate_text/string?=null
    --client_certificate_text/string?=null
    --client_key/string?=null:
  if root_certificate_text:
    client_certificate := null
    if client_certificate_text:
      client_certificate = tls.Certificate (x509.Certificate.parse client_certificate_text) client_key
    root_certificate := x509.Certificate.parse root_certificate_text
    return mqtt.TcpTransport.tls network --host=host --port=port
        --server_name=host
        --root_certificates=[root_certificate]
        --certificate=client_certificate
  else:
    return mqtt.TcpTransport network --host=host --port=port

topic_config_for_ device_id/string -> string:
  return "toit/devices/$device_id/config"

topic_lock_for_ device_id/string -> string:
  config_topic := topic_config_for_ device_id
  return "$config_topic/writer"

topic_revision_for_ device_id/string -> string:
  config_topic := topic_config_for_ device_id
  return "$config_topic/revision"

topic_presence_for_ device_id/string -> string:
  return "toit/devices/presence/$device_id"
