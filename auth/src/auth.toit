// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import http
import net
import system
import host.pipe

import .oauth
import .token
import .utils_

export OAuth

/**
An authentication provider.

Authentication providers log in a user and provide the necessary information to
  authenticate requests.
*/
interface AuthProvider:
  /**
  Ensures that the user is authenticated.

  If the user is not authenticated, the $block is called with a URL the user
    should visit to authenticate. A second argument to $block provides
    a key the user has to enter at the URL. If the second argument is null,
    then the user does not have to enter a key.
  */
  ensure-authenticated [block] -> none

  /**
  The authentication headers for the current user.
  */
  auth-headers -> Map

  /**
  Whether the user is authenticated.

  Only looks at the local state, not at the server. If the server has
    invalidated the authentication, this will still return true.
  */
  is-authenticated -> bool

/**
An interface to store authentication information locally.

On desktops this should be the config file.
On mobile this could be something like HiveDB/Isar.
*/
interface LocalStorage:
  /**
  Whether the storage contains any authorization information.
  */
  has-auth -> bool

  /**
  Returns the stored authorization information.
  If none exists, returns null.
  */
  get-auth -> any?

  /**
  Sets the authorization information to $value.

  The $value must be JSON-encodable.
  */
  set-auth value/any -> none

  /**
  Removes any authorization information.
  */
  remove-auth -> none

/**
A simple implementation of $LocalStorage that simply discards all data.
*/
class NoLocalStorage implements LocalStorage:
  has-auth -> bool: return false
  get-auth -> any?: return null
  set-auth value/any: return
  remove-auth -> none: return

abstract class TokenAuthProvider implements AuthProvider:
  root-certificates_/List
  token_/Token? := null
  local-storage_/LocalStorage

  constructor --root-certificates/List --local-storage/LocalStorage:
    local-storage_ = local-storage
    root-certificates_ = root-certificates
    if local-storage_.has-auth:
      token_ = Token.from-json local-storage_.get-auth

  is-authenticated -> bool:
    return token_ != null and not token_.has-expired

  /** See $AuthProvider.ensure-authenticated. */
  ensure-authenticated --network/net.Client?=null [block] -> none:
    if is-authenticated: return
    if token_ != null:
      token_ = refresh token_ --network=network
      save_
      return

    token_ = do-authentication_ --network=network block
    save_

  /** See $AuthProvider.auth-headers. */
  auth-headers -> Map:
    if token_ == null: return {:}
    return token_.auth-headers

  save_ -> none:
    if token_ == null: throw "INVALID_STATE"
    local-storage_.set-auth token_.to-json

  abstract refresh --network/net.Client?=null token/Token -> Token
  abstract do-authentication_ --network/net.Client?=null [block] -> Token

/**
Opens the default browser with the given URL.

Only works on Linux, macOS and Windows.
If launching the browser fails, no error is reported.
*/
open-browser url/string -> none:
  platform := system.platform
  catch:
    command/string? := null
    args/List? := null
    if platform == system.PLATFORM-LINUX:
      command = "xdg-open"
      args = [ url ]
    else if platform == system.PLATFORM-MACOS:
      command = "open"
      args = [ url ]
    else if platform == system.PLATFORM-WINDOWS:
      command = "cmd"
      escaped-url := url.replace "&" "^&"
      args = [ "/c", "start", escaped-url ]
    // If we have a supported platform try to open the URL.
    // For all other platforms don't do anything.
    if command != null:
      fork-data := pipe.fork
          true  // Use path.
          pipe.PIPE-CREATED  // Stdin.
          pipe.PIPE-CREATED  // Stdout.
          pipe.PIPE-CREATED  // Stderr.
          command
          [ command ] + args
      pid := fork-data[3]
      task --background::
        // The 'open' command should finish in almost no time.
        // If it takes more than 20 seconds, kill it.
        exception := catch: with-timeout --ms=20_000:
          pipe.wait-for pid
        if exception == DEADLINE-EXCEEDED-ERROR:
          SIGKILL ::= 9
          catch: pipe.kill_ pid SIGKILL
