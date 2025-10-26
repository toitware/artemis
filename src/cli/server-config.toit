// Copyright (C) 2022 Toitware ApS. All rights reserved.

import cli show Cli
import .config
import ..shared.server-config
import certificate-roots
import crypto.sha256
import encoding.base64

export ServerConfig ServerConfigSupabase ServerConfigHttp

ORIGINAL-SUPABASE-SERVER-URI ::= "voisfafsfolxhqpkudzd.supabase.co"

DEFAULT-ARTEMIS-SERVER-CONFIG ::= ServerConfigSupabase
    "Artemis"
    --host="artemis-api.toit.io"
    --anon="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZvaXNmYWZzZm9seGhxcGt1ZHpkIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NzMzNzQyNDEsImV4cCI6MTk4ODk1MDI0MX0.dmfxNl5WssxnZ8jpvGJeryg4Fd47fOcrlZ8iGrHj2e4"
    --root-certificate-name="Baltimore CyberTrust Root"

/**
Reads the server configuration with the given $key from the $cli's config.
*/
get-server-from-config --cli/Cli --key/string -> ServerConfig?:
  servers := cli.config.get CONFIG-SERVERS-KEY
  server-name := cli.config.get key

  if not servers:
    if server-name:
      if server-name == DEFAULT-ARTEMIS-SERVER-CONFIG.name:
        return DEFAULT-ARTEMIS-SERVER-CONFIG
      cli.ui.abort "No server entry for '$server-name' in the config."

    // No server information in the config. Return the default server.
    return DEFAULT-ARTEMIS-SERVER-CONFIG

  if not server-name:
    if key == CONFIG-ARTEMIS-DEFAULT-KEY or key == CONFIG-BROKER-DEFAULT-KEY:
      return DEFAULT-ARTEMIS-SERVER-CONFIG
    return null

  return get-server-from-config --cli=cli --name=server-name

/**
Reads the server configuration with the given $name from the $cli's config.
*/
get-server-from-config --cli/Cli --name/string -> ServerConfig?:
  servers := cli.config.get CONFIG-SERVERS-KEY
  if not servers or not servers.contains name:
    if name == DEFAULT-ARTEMIS-SERVER-CONFIG.name:
      return DEFAULT-ARTEMIS-SERVER-CONFIG
    cli.ui.abort "No server entry for '$name' in the config."

  json-map := servers[name]

  result := ServerConfig.from-json name json-map
      --der-deserializer=: base64.decode it

  if result is ServerConfigSupabase:
    // If the server config is for supabase, and it uses the original
    // server URI, update it to use the new one.
    supabase-config := result as ServerConfigSupabase
    if supabase-config.host == ORIGINAL-SUPABASE-SERVER-URI:
      json-map["host"] = DEFAULT-ARTEMIS-SERVER-CONFIG.host
      cli.ui.emit --info
          "Using updated Artemis server URI: $DEFAULT-ARTEMIS-SERVER-CONFIG.host"
      return ServerConfig.from-json name json-map
          --der-deserializer=: base64.decode it

  return result

get-servers-from-config --cli/Cli -> List:
  config := cli.config
  default-name := DEFAULT-ARTEMIS-SERVER-CONFIG.name
  servers := config.get CONFIG-SERVERS-KEY
  if not servers:
    return [default-name]
  result := []
  if not servers.contains default-name:
    result.add default-name
  result.add-all servers.keys
  return result

has-server-in-config --cli/Cli server-name/string -> bool:
  config := cli.config
  servers := config.get CONFIG-SERVERS-KEY
  return (servers != null) and servers.contains server-name

add-server-to-config --cli/Cli server-config/ServerConfig:
  config := cli.config
  servers := config.get CONFIG-SERVERS-KEY --init=: {:}

  json := server-config.to-json --der-serializer=: base64.encode it
  servers[server-config.name] = json

/**
Serializes a certificate to a string.
Deduplicates them in the process.

Stores the certificate in the $serialized-certificates map, which is of
  type string -> ByteArray.
*/
serialize-certificate certificate-der/ByteArray serialized-certificates/Map -> string:
  sha := sha256.Sha256
  sha.add certificate-der
  certificate-key := "certificate-$(base64.encode sha.get[0..8])"
  serialized-certificates[certificate-key] = certificate-der
  return certificate-key

/**
Serializes the given $server-config as JSON.
Replaces all certificates with an ID and stores the original bytes in the
  $serialized-certificates map.
*/
server-config-to-service-json server-config/ServerConfig serialized-certificates/Map -> any:
  server-config.fill-certificate-ders: certificate-roots.MAP[it].raw
  return server-config.to-service-json --der-serializer=:
    serialize-certificate it serialized-certificates
