// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import http
import host.pipe
import log
import monitor
import net
import .supabase

/**
A class that handles all authentication related functionality of the Supabase API.
*/
class Auth:
  client_/Client

  constructor .client_:

  /**
  Computes an OAuth URL for the given $provider.

  The user should follow the URL and authenticate there. They are then redirected to
    the given $redirect_url, which must extract the session information.

  Use $finish_oauth_sign_in to provide the returned information to this instance.
  */
  compute_authenticate_url --redirect_url/string --provider/string -> string:
    return "https://$(client_.host_)/auth/v1/authorize?provider=github&redirect_to=$redirect_url"

  /**
  Finishes the OAuth sign-in.

  When the user authenticates on an URL that is provided by $compute_authenticate_url,
    then they are redirected to another URL with the authentication information in the
    hash part of the URL. The page should change this to a query part and then call this
    method with the path of the URL.
  */
  finish_oauth_sign_in path/string -> none:
    // Extract the session information.
    question_mark_pos := path.index_of "?"
    path = path[question_mark_pos + 1..]
    query_parameters := {:}
    parts := path.split "&"
    parts.do: | part |
      equals_pos := part.index_of "="
      key := part[..equals_pos]
      value := part[equals_pos + 1..]
      query_parameters[key] = value

    access_token := query_parameters["access_token"]
    expires_in := int.parse query_parameters["expires_in"]
    refresh_token := query_parameters["refresh_token"]
    token_type := query_parameters["token_type"]

    session := Session_
        --access_token=access_token
        --expires_in=expires_in
        --refresh_token=refresh_token
        --token_type=token_type

    client_.set_session_ session

  sign_up --email/string --password/string -> none:
    response := client_.request_
        --method=http.POST
        --path="/auth/v1/signup"
        --payload={
          "email": email,
          "password": password,
        }
    if response and response is Map:
      if (response.get "email") == email: return
      if user := response.get "user":
        if (user.get "email") == email: return
    throw "Failed to sign up"

  sign_in --email/string --password/string -> none:
    response := client_.request_
        --method=http.POST
        --path="/auth/v1/token"
        --payload={
          "email": email,
          "password": password,
        }
        --query_parameters={
          "grant_type": "password",
        }
    session := Session_
        --access_token=response["access_token"]
        --expires_in=response["expires_in"]
        --refresh_token=response["refresh_token"]
        --token_type=response["token_type"]
    client_.set_session_ session

  sign_in --provider/string --ui/Ui -> none:
    network := net.open
    try:
      server_socket := network.tcp_listen 0
      server := http.Server --logger=(log.default.with_level log.FATAL_LEVEL)
      port := server_socket.local_address.port

      authenticate_url := compute_authenticate_url
          --redirect_url="http://localhost:$port/auth"
          --provider="github"

      ui.info "Please authenticate at $authenticate_url"
      catch:
        if platform == PLATFORM_LINUX:
          pipe.backticks "xdg-open" authenticate_url
        else if platform == PLATFORM_MACOS:
          pipe.backticks "open" authenticate_url
        else if platform == PLATFORM_WINDOWS:
          pipe.backticks "start" authenticate_url

      session_latch := monitor.Latch
      server_task := task::
        server.listen server_socket:: | request/http.Request writer/http.ResponseWriter |
          if request.path.starts_with "/success":
            finish_oauth_sign_in request.path
            writer.write "You can close this window now."
            session_latch.set true
          else if request.path.starts_with "/auth":
            // TODO(florian): extract error if there:
            // ```
            // http://localhost:41055/auth?error=server_error&error_description=Database+error+saving+new+user
            // ```
            writer.write """
            <html>
              <body>
                <p id="body">
                This page requires JavaScript to continue.
                </p>
                <script type="text/javascript">
                  const req = new XMLHttpRequest();
                  req.addEventListener("load", function() {
                    document.getElementById("body").innerHTML = "You can close this window now.";
                  });
                  req.open("GET", "http://localhost:$port/success?" + window.location.hash.substring(1));
                  req.send();
                  document.getElementById("body").innerHTML = "Transmitting data to CLI...";
                </script>
              </body>
            </html>
            """
          else:
            writer.write "Invalid request."

      session_latch.get
      sleep --ms=1  // Give the server time to respond with the success message.
      server_task.cancel
    finally:
      network.close

  refresh_token:
    if client_.session_ == null: throw "No session available."
    response := client_.request_
        --method=http.POST
        --path="/auth/v1/token"
        --query_parameters={
          "grant_type": "refresh_token",
        }
        --payload={
          "refresh_token": client_.session_.refresh_token,
        }
    session := Session_
        --access_token=response["access_token"]
        --expires_in=response["expires_in"]
        --refresh_token=response["refresh_token"]
        --token_type=response["token_type"]
    client_.set_session_ session

  /**
  Returns the currently authenticated user.
  */
  // TODO(florian): We should have this information cached when we sign in.
  get_current_user -> Map?:
    if client_.session_ == null: throw "No session available."
    response := client_.request_
        --method=http.GET
        --path="/auth/v1/user"
    return response

  /**
  Updates the currently authenticated user.
  */
  update_current_user data/Map -> none:
    if client_.session_ == null: throw "No session available."
    client_.request_
        --method=http.PUT
        --path="/auth/v1/user"
        --payload=data

class Session_:
  access_token/string

  // The number of seconds until the access token expires after it was issued.
  expires_in/int

  refresh_token/string
  token_type/string

  constructor
      --.access_token
      --.expires_in
      --.refresh_token
      --.token_type:

  constructor.from_json json/Map:
    return Session_
        --access_token=json["access_token"]
        --expires_in=json["expires_in"]
        --refresh_token=json["refresh_token"]
        --token_type=json["token_type"]

  to_json -> Map:
    return {
      "access_token": access_token,
      "expires_in": expires_in,
      "refresh_token": refresh_token,
      "token_type": token_type,
    }
