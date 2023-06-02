// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

class Token:
  access_token/string
  token_type/string

  expires_at/Time?
  refresh_token/string?

  scopes/List?

  /**
  Constructs a new token.

  The $expires_in_s is the number of seconds until the access token expires
    after it was issued. We assume that the token was issued at the time of
    the call to the constructor.
  */
  constructor
      --.access_token
      --.token_type
      --expires_in_s/int?
      --.refresh_token
      --.scopes=null:
    expires_at = expires_in_s and (Time.now + (Duration --s=expires_in_s))

  constructor.from_json json/Map:
    access_token = json["access_token"]
    token_type = json["token_type"].to_ascii_lower

    expires_at_epoch_ms := json.get "expires_at_epoch_ms"
    expires_at = expires_at_epoch_ms and Time.epoch --ms=expires_at_epoch_ms
    refresh_token = json.get "refresh_token"

    scopes = json.get "scopes"

  to_json -> Map:
    result := {
      "access_token": access_token,
      "token_type": token_type,

    }
    if expires_at: result["expires_at_epoch_ms"] = expires_at.ms_since_epoch
    if refresh_token: result["refresh_token"] = refresh_token

    if scopes: result["scopes"] = scopes
    return result

  has_expired --min_remaining/Duration=Duration.ZERO -> bool:
    if not expires_at: return false
    return Time.now + min_remaining >= expires_at

  auth_headers -> Map:
    if token_type != "bearer":
      throw "Unsupported token type: $token_type"
    return {
      "Authorization": "Bearer $access_token"
    }
