// Copyright (C) 2022 Toitware ApS. All rights reserved.

import monitor
import mqtt
import mqtt.transport as mqtt
import net
import net.x509
import encoding.ubjson
import tls
import .server_config

/**
MQTT functionality.

This library contains functionality and constants that are shared between
  the CLI and the service.

Ideally, there is (or should be) a clear separation between the parts that
  are here because both sides agree on them, and the parts that are
  just generic and could live in their own package.
*/

create_transport_from_server_config -> mqtt.Transport
    network/net.Interface
    server_config/ServerConfigMqtt
    [--certificate_provider]:

  root_certificate_der := server_config.root_certificate_der
  if not root_certificate_der and server_config.root_certificate_name:
    root_certificate_der = certificate_provider.call server_config.root_certificate_name
  return create_transport network
      --host=server_config.host
      --port=server_config.port
      --root_certificate_der=root_certificate_der
      --client_certificate_der=server_config.client_certificate_der
      --client_key_der=server_config.client_private_key_der

create_transport network/net.Interface -> mqtt.Transport
    --host/string
    --port/int
    --root_certificate_der/ByteArray?=null
    --client_certificate_der/ByteArray?=null
    --client_key_der/ByteArray?=null:
  if root_certificate_der:
    client_certificate := null
    if client_certificate_der:
      client_certificate = tls.Certificate (x509.Certificate.parse client_certificate_der) client_key_der
    root_certificate := x509.Certificate.parse root_certificate_der
    return mqtt.TcpTransport.tls network --host=host --port=port
        --server_name=host
        --root_certificates=[root_certificate]
        --certificate=client_certificate
  else:
    return mqtt.TcpTransport network --host=host --port=port

topic_goal_for_ device_id/string -> string:
  return "toit/devices/$device_id/goal"

topic_lock_for_ device_id/string -> string:
  config_goal := topic_goal_for_ device_id
  return "$config_goal/writer"

topic_revision_for_ device_id/string -> string:
  config_goal := topic_goal_for_ device_id
  return "$config_goal/revision"

topic_state_for_ device_id/string -> string:
  return "toit/devices/$device_id/state"

topic_presence_for_ device_id/string -> string:
  return "toit/devices/presence/$device_id"
