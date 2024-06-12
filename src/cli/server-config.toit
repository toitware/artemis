// Copyright (C) 2022 Toitware ApS. All rights reserved.

import .config
import ..shared.server-config
import certificate-roots
import crypto.sha256
import encoding.base64

export ServerConfig ServerConfigSupabase ServerConfigHttp

DEFAULT-ARTEMIS-SERVER-CONFIG ::= ServerConfigSupabase
    "Artemis"
    --host="voisfafsfolxhqpkudzd.supabase.co"
    --anon="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZvaXNmYWZzZm9seGhxcGt1ZHpkIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NzMzNzQyNDEsImV4cCI6MTk4ODk1MDI0MX0.dmfxNl5WssxnZ8jpvGJeryg4Fd47fOcrlZ8iGrHj2e4"
    --root-certificate-name="Baltimore CyberTrust Root"

/**
Reads the server configuration with the given $key from the $config.
*/
get-server-from-config config/Config --key/string -> ServerConfig:
  server-name := config.get key
  if not server-name:
    if key == CONFIG-ARTEMIS-DEFAULT-KEY:
      return DEFAULT-ARTEMIS-SERVER-CONFIG
    throw "No default broker configured $key"

  return get-server-from-config config --name=server-name

/**
Reads the server configuration with the given $name from the $config.
*/
get-server-from-config config/Config --name/string -> ServerConfig:
  servers := config.get CONFIG-SERVERS-KEY
  if not servers: return DEFAULT-ARTEMIS-SERVER-CONFIG

  json-map := servers.get name
  if not json-map: throw "No broker named $name"

  return ServerConfig.from-json name json-map
      --der-deserializer=: base64.decode it

has-server-in-config config/Config server-name/string -> bool:
  servers := config.get CONFIG-SERVERS-KEY
  return (servers != null) and servers.contains server-name

add-server-to-config config/Config server-config/ServerConfig:
  servers := config.get CONFIG-SERVERS-KEY --init=:{:}

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
