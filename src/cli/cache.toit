// Copyright (C) 2022 Toitware ApS. All rights reserved.

import crypto.sha1
import crypto.sha256
import encoding.base64
import uuid show Uuid
import .server-config
import ..shared.scope show Scope

/**
Manages cache keys.
*/

cache-key-application-image id/Uuid --broker-config/ServerConfig -> string:
  return "$broker-config.cache-key/application/images/$(id).image"

cache-key-pod-parts -> string
    --broker-config/ServerConfig
    --scope/Scope
    --part-id/string:
  return "$broker-config.cache-key/$scope.as-uuid/pod/parts/$part-id"

cache-key-pod-manifest -> string
    --broker-config/ServerConfig
    --scope/Scope
    --pod-id/Uuid:
  return "$broker-config.cache-key/$scope.as-uuid/pod/manifest/$pod-id"

cache-key-patch -> string
    --broker-config/ServerConfig
    --scope/Scope
    --patch-id/string:
  return "$broker-config.cache-key/$scope.as-uuid/patches/$patch-id"

CACHE-ARTIFACT-KIND-ENVELOPE ::= "envelope"
CACHE-ARTIFACT-KIND-PARTITION-TABLE ::= "partitions"

cache-key-url-artifact --url/string --kind/string -> string:
  HTTP-URL-PREFIX ::= "http://"
  HTTPS-URL-PREFIX ::= "https://"
  filename/string := ?
  if kind == CACHE-ARTIFACT-KIND-ENVELOPE:
    filename = "firmware.envelope"
  else if kind == CACHE-ARTIFACT-KIND-PARTITION-TABLE:
    filename = "partitions"  // We don't know whether it's a '.bin' or '.csv'.
  else:
    throw "Unknown artifact kind: $kind"
  url_without_prefix := (url.trim --left HTTP-URL-PREFIX).trim --left HTTPS-URL-PREFIX
  return "$(kind)s/$url_without_prefix/$filename"

cache-key-git-app --url/string -> string:
  // The URL might have weird characters or might be very long, so hash it.
  // Any hash function would do.
  hash64 := base64.encode --url-mode (sha1.sha1 url)
  url = url.trim --right ".git"
  // For the most common URLs, add the organization and name.
  // This isn't really necessary, but makes it nicer to understand what's in the cache.
  // For example: https://github.com/toitware/cellular.git
  //     becomes: hSGHt2yVMnTuWlP8z6GtRHc0_l8-toitware-cellular
  GIT-PROVIDERS ::= [
    "https://github.com/",
    "git@github.com:",
    "https://gitlab.com/",
    "git@gitlab.com:",
  ]
  GIT-PROVIDERS.do: | provider/string |
    if url.starts-with provider:
      url = url.trim --left provider
      human := url.replace --all "/" "-"
      return "git-app/$hash64-$human"
  return hash64

cache-key-sdk --version/string -> string:
  return "sdks/$version"
