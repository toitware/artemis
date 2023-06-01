// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import http
import net
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
  ensure_authenticated [block] -> none

  /**
  The authentication headers for the current user.
  */
  auth_headers -> Map

  /**
  Whether the user is authenticated.

  Only looks at the local state, not at the server. If the server has
    invalidated the authentication, this will still return true.
  */
  is_authenticated -> bool


/**
An interface to store authentication information locally.

On desktops this should be the config file.
On mobile this could be something like HiveDB/Isar.
*/
interface LocalStorage:
  /**
  Whether the storage contains any authorization information.
  */
  has_auth -> bool

  /**
  Returns the stored authorization information.
  If none exists, returns null.
  */
  get_auth -> any?

  /**
  Sets the authorization information to $value.

  The $value must be JSON-encodable.
  */
  set_auth value/any -> none

  /**
  Removes any authorization information.
  */
  remove_auth -> none

/**
A simple implementation of $LocalStorage that simply discards all data.
*/
class NoLocalStorage implements LocalStorage:
  has_auth -> bool: return false
  get_auth -> any?: return null
  set_auth value/any: return
  remove_auth -> none: return

abstract class TokenAuthProvider implements AuthProvider:
  root_certificates_/List
  token_/Token? := null
  local_storage_/LocalStorage

  constructor --root_certificates/List --local_storage/LocalStorage:
    local_storage_ = local_storage
    root_certificates_ = root_certificates
    if local_storage_.has_auth:
      token_ = Token.from_json local_storage_.get_auth

  is_authenticated -> bool:
    return token_ != null and not token_.has_expired

  /** See $AuthProvider.ensure_authenticated. */
  ensure_authenticated --network/net.Client?=null [block] -> none:
    if is_authenticated: return
    if token_ != null:
      token_ = refresh token_ --network=network
      save_
      return

    token_ = do_authentication_ --network=network block
    save_

  /** See $AuthProvider.auth_headers. */
  auth_headers -> Map:
    if token_ == null: return {:}
    return token_.auth_headers

  save_ -> none:
    if token_ == null: throw "INVALID_STATE"
    local_storage_.set_auth token_.to_json

  abstract refresh --network/net.Client?=null token/Token -> Token
  abstract do_authentication_ --network/net.Client?=null [block] -> Token


/**
Opens the default browser with the given URL.

Only works on Linux, macOS and Windows.
If launching the browser fails, no error is reported.
*/
open_browser url/string -> none:
  catch:
    command/string? := null
    args/List? := null
    if platform == PLATFORM_LINUX:
      command = "xdg-open"
      args = [ url ]
    else if platform == PLATFORM_MACOS:
      command = "open"
      args = [ url ]
    else if platform == PLATFORM_WINDOWS:
      command = "cmd"
      escaped_url := url.replace "&" "^&"
      args = [ "/c", "start", escaped_url ]
    // If we have a supported platform try to open the URL.
    // For all other platforms don't do anything.
    if command != null:
      fork_data := pipe.fork
          true  // Use path.
          pipe.PIPE_CREATED  // Stdin.
          pipe.PIPE_CREATED  // Stdout.
          pipe.PIPE_CREATED  // Stderr.
          command
          [ command ] + args
      pid := fork_data[3]
      task --background::
        // The 'open' command should finish in almost no time.
        // If it takes more than 20 seconds, kill it.
        exception := catch: with_timeout --ms=20_000:
          pipe.wait_for pid
        if exception == DEADLINE_EXCEEDED_ERROR:
          SIGKILL ::= 9
          catch: pipe.kill_ pid SIGKILL
