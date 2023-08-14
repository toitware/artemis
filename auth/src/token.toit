// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

class Token:
  access-token/string
  token-type/string

  expires-at/Time?
  refresh-token/string?

  scopes/List?

  /**
  Constructs a new token.

  The $expires-in-s is the number of seconds until the access token expires
    after it was issued. We assume that the token was issued at the time of
    the call to the constructor.
  */
  constructor
      --.access-token
      --.token-type
      --expires-in-s/int?
      --.refresh-token
      --.scopes=null:
    expires-at = expires-in-s and (Time.now + (Duration --s=expires-in-s))

  constructor.from-json json/Map:
    access-token = json["access_token"]
    token-type = json["token_type"].to-ascii-lower

    expires-at-epoch-ms := json.get "expires_at_epoch_ms"
    expires-at = expires-at-epoch-ms and Time.epoch --ms=expires-at-epoch-ms
    refresh-token = json.get "refresh_token"

    scopes = json.get "scopes"

  to-json -> Map:
    result := {
      "access_token": access-token,
      "token_type": token-type,

    }
    if expires-at: result["expires_at_epoch_ms"] = expires-at.ms-since-epoch
    if refresh-token: result["refresh_token"] = refresh-token

    if scopes: result["scopes"] = scopes
    return result

  has-expired --min-remaining/Duration=Duration.ZERO -> bool:
    if not expires-at: return false
    return Time.now + min-remaining >= expires-at

  auth-headers -> Map:
    if token-type != "bearer":
      throw "Unsupported token type: $token-type"
    return {
      "Authorization": "Bearer $access-token"
    }
