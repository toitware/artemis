// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .config
import ..shared.server_config
import certificate_roots
import crypto.sha256
import encoding.base64

export ServerConfig ServerConfigSupabase ServerConfigHttpToit

DEFAULT_ARTEMIS_SERVER_CONFIG ::= ServerConfigSupabase
    "Artemis"
    --host="voisfafsfolxhqpkudzd.supabase.co"
    --anon="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZvaXNmYWZzZm9seGhxcGt1ZHpkIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NzMzNzQyNDEsImV4cCI6MTk4ODk1MDI0MX0.dmfxNl5WssxnZ8jpvGJeryg4Fd47fOcrlZ8iGrHj2e4"
    --root_certificate_name="Baltimore CyberTrust Root"

/**
Reads the server configuration with the given $key from the $config.
*/
get_server_from_config config/Config key/string -> ServerConfig:
  servers := config.get CONFIG_SERVERS_KEY
  if not servers: return DEFAULT_ARTEMIS_SERVER_CONFIG

  // We keep the name "broker" here, as the CLI user should only ever deal with
  // the term "broker". Internally we use it also to configure the Artemis server.
  if not servers: throw "No brokers configured"
  server_name := config.get key
  if not server_name: throw "No default broker configured $key"
  json_map := servers.get server_name
  if not json_map: throw "No broker named $server_name"

  return ServerConfig.from_json server_name json_map
      --der_deserializer=: base64.decode it

has_server_in_config config/Config server_name/string -> bool:
  servers := config.get CONFIG_SERVERS_KEY
  return servers and servers.contains server_name

add_server_to_config config/Config server_config/ServerConfig:
  servers := config.get CONFIG_SERVERS_KEY --init=:{:}

  json := server_config.to_json --der_serializer=: base64.encode it
  servers[server_config.name] = json

/**
Serializes a certificate to a string.
Deduplicates them in the process.

Stores the certificate in the $serialized_certificates map, which is of
  type string -> ByteArray.
*/
serialize_certificate certificate_der/ByteArray serialized_certificates/Map -> string:
  sha := sha256.Sha256
  sha.add certificate_der
  certificate_key := "certificate-$(base64.encode sha.get[0..8])"
  serialized_certificates[certificate_key] = certificate_der
  return certificate_key

/**
Serializes the given $server_config as JSON.
Replaces all certificates with an ID and stores the original bytes in the
  $serialized_certificates map.
*/
server_config_to_service_json server_config/ServerConfig serialized_certificates/Map -> any:
  server_config.fill_certificate_ders: certificate_roots.MAP[it]
  return server_config.to_json --der_serializer=:
    serialize_certificate it serialized_certificates
