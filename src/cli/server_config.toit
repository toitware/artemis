// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .config
import ..shared.server_config
import certificate_roots
import crypto.sha256
import encoding.base64

/**
Reads the server configuration with the given $server_name from the $config.
*/
get_server_from_config config/Config server_name/string? default_key/string -> ServerConfig:
  servers := config.get CONFIG_SERVERS_KEY
  // We keep the name "broker" here, as the CLI user should only ever deal with
  // the term "broker". Internally we use it also to configure the Artemis server.
  if not servers: throw "No brokers configured"
  if not server_name: server_name = servers.get default_key
  if not server_name: throw "No default broker configured"
  json_map := servers.get server_name
  if not json_map: throw "No broker named $server_name"

  // Certificates weren't deduplicated. The block just returns 'it'.
  return ServerConfig.from_json server_name json_map --certificate_text_provider=: it

has_server_in_config config/Config server_name/string -> bool:
  servers := config.get CONFIG_SERVERS_KEY
  return servers and servers.contains server_name

add_server_to_config config/Config server_config/ServerConfig:
  servers := config.get CONFIG_SERVERS_KEY --init=:{:}

  // No need to deduplicate certificates. The block just returns 'it'.
  json := server_config.to_json --certificate_deduplicator=: it
  servers[server_config.name] = json

/**
Serializes a certificate to a string.
Deduplicates them in the process.
*/
deduplicate_certificate certificate_string/string deduplicated_certificates/Map -> string:
  sha := sha256.Sha256
  sha.add certificate_string
  certificate_key := "certificate-$(base64.encode sha.get[0..8])"
  deduplicated_certificates[certificate_key] = certificate_string
  return certificate_key

server_config_to_service_json server_config/ServerConfig deduplicated_certificates/Map -> any:
  server_config.fill_certificate_texts: certificate_roots.MAP[it]
  return server_config.to_json --certificate_deduplicator=:
    deduplicate_certificate it deduplicated_certificates
