// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import bytes
import http
import net
import net.x509
import http.status_codes
import encoding.json as json_encoding
import encoding.url as url_encoding
import reader show SizedReader BufferedReader

import .auth

interface ServerConfig:
  host -> string
  anon -> string
  root_certificate_name -> string?
  root_certificate_der -> ByteArray?

/**
An interface for interactions with the user.
*/
interface Ui:
  info str/string

/**
A client for the Supabase API.

Supabase provides several different APIs under one umbrella.

A frontend ('Kong'), takes the requests and forwards them to the correct
  backend.
Each supported backend is available through a different getter.
For example, the Postgres backend is available through the $rest getter, and
  the storage backend is available through $storage.
*/
class Client:
  http_client_/http.Client? := null
  local_storage_/LocalStorage
  session_/Session_? := null

  /**
  The used network interface.
  This field is only set, if the $close function should close the network.
  */
  network_to_close_/net.Interface? := null

  /**
  The host of the Supabase project.
  */
  host_/string

  /**
  The anonymous key of the Supabase project.

  This key is used as api key.
  If the user is not authenticated the client uses this key as the bearer.
  */
  anon_/string

  rest_/PostgRest? := null
  storage_/Storage? := null
  auth_/Auth? := null


  constructor network/net.Interface?=null
      --host/string
      --anon/string
      --local_storage/LocalStorage=NoLocalStorage:
    host_ = host
    anon_ = anon

    if not network:
      network = network_to_close_ = net.open

    http_client_ = http.Client network

    local_storage_ = local_storage

  constructor.tls network/net.Interface?=null
      --host/string
      --anon/string
      --root_certificates/List
      --local_storage/LocalStorage=NoLocalStorage:
    host_ = host
    anon_ = anon

    if not network:
      network = network_to_close_ = net.open

    http_client_ = http.Client.tls network --root_certificates=root_certificates

    local_storage_ = local_storage

  constructor network/net.Interface?=null
      --server_config/ServerConfig
      --local_storage/LocalStorage=NoLocalStorage
      [--certificate_provider]:
    root_certificate_der := server_config.root_certificate_der
    if not root_certificate_der and server_config.root_certificate_name:
      root_certificate_der = certificate_provider.call server_config.root_certificate_name

    if root_certificate_der:
      certificate := x509.Certificate.parse root_certificate_der
      return Client.tls network
          --local_storage=local_storage
          --host=server_config.host
          --anon=server_config.anon
          --root_certificates=[certificate]
    else:
      return Client network
          --host=server_config.host
          --anon=server_config.anon
          --local_storage=local_storage

  /**
  Ensures that the user is authenticated.

  If a session is stored in the local storage, it is used to authenticate the
    user.

  If no session is stored, or the refresh failed, calls the given $block with $auth
    as argument. This can be used to sign in the user, using $Auth.sign_in.

  # Examples
  A simple example where the user is signed in using email and password:
  ```
  client.ensure_authenticated:
    it.sign_in --email="email" --password="password"
  ```

  Or, using oauth:
  ```
  client.ensure_authenticated:
    it.sign_in --provider="github" --ui=ui
  ```
  */
  ensure_authenticated [block]:
    if local_storage_.has_auth:
      catch:
        session_ = Session_.from_json local_storage_.get_auth
        // TODO(florian): no need to refresh if the token is still valid.
        auth.refresh_token
        return
      // There was an exception.
      // Clear the stored session, and run the block for a fresh authentication.
      local_storage_.remove_auth
    block.call auth

  close -> none:
    // TODO(florian): call close on the http client (when that's possible).
    // TODO(florian): add closing in a finalizer.
    http_client_ = null
    if network_to_close_:
      network_to_close_.close
      network_to_close_ = null

  is_closed -> bool:
    return http_client_ == null

  rest -> PostgRest:
    if not rest_: rest_ = PostgRest this
    return rest_

  storage -> Storage:
    if not storage_: storage_ = Storage this
    return storage_

  auth -> Auth:
    if not auth_: auth_ = Auth this
    return auth_

  set_session_ session/Session_?:
    session_ = session
    if session:
      local_storage_.set_auth session.to_json
    else:
      local_storage_.remove_auth

  is_success_status_code_ code/int -> bool:
    return 200 <= code <= 299

  /**
  Does a request to the Supabase API, and returns the response without
    parsing it.

  It is the responsibility of the caller to drain the response.

  Query parameters can be provided in two ways:
  - with the $query parameter is a string that is appended to the path. It must
    be properly URL encoded (also known as percent-encoding), or
  - with the $query_parameters parameter, which is a map from keys to values.
    The value for each key must be a string or a list of strings. In the latter
    case, each value is added as a separate query parameter.
  It is an error to provide both $query and $query_parameters.
  */
  request_ --raw_response/bool -> http.Response
      --path/string
      --method/string
      --bearer/string? = null
      --query/string? = null
      --query_parameters/Map? = null
      --headers/http.Headers? = null
      --payload/any = null:

    if query and query_parameters:
      throw "Cannot provide both query and query_parameters"

    headers = headers ? headers.copy : http.Headers

    if not bearer:
      if not session_: bearer = anon_
      else: bearer = session_.access_token
    headers.set "Authorization" "Bearer $bearer"

    headers.add "apikey" anon_

    question_mark_pos := path.index_of "?"
    if question_mark_pos >= 0:
      // Replace the existing query parameters with ours.
      path = path[..question_mark_pos]
    if query_parameters:
      encoded_params := []
      query_parameters.do: | key value |
        encoded_key := url_encoding.encode key
        if value is List:
          value.do:
            encoded_params.add "$encoded_key=$(url_encoding.encode it)"
        else:
          encoded_params.add "$encoded_key=$(url_encoding.encode value)"
      path = "$path?$(encoded_params.join "&")"
    else if query:
      path = "$path?$query"

    response/http.Response := ?
    if method == http.GET:
      if payload: throw "GET requests cannot have a payload"
      response = http_client_.get host_ path --headers=headers
    else if method == "PATCH" or method == http.DELETE or method == http.PUT:
      // TODO(florian): the http client should support PATCH.
      // TODO(florian): we should only do this if the payload is a Map.
      encoded := json_encoding.encode payload
      headers.set "Content-Type" "application/json"
      request := http_client_.new_request method host_ path --headers=headers
      request.body = bytes.Reader encoded
      response = request.send
    else:
      if method != http.POST: throw "UNIMPLEMENTED"
      if payload is Map:
        response = http_client_.post_json payload
            --host=host_
            --path=path
            --headers=headers
      else:
        response = http_client_.post payload
            --host=host_
            --path=path
            --headers=headers

    return response

  /**
  Variant of $(request_ --raw_response --path --method).

  Does a request to the Supabase API, and extracts the response.
  If $parse_response_json is true, then parses the response as a JSON
    object.
  Otherwise returns it as a byte array.
  */
  request_ -> any
      --path/string
      --method/string
      --bearer/string? = null
      --query/string? = null
      --query_parameters/Map? = null
      --headers/http.Headers? = null
      --parse_response_json/bool = true
      --payload/any = null:
    response := request_
        --raw_response
        --path=path
        --method=method
        --bearer=bearer
        --query=query
        --query_parameters=query_parameters
        --headers=headers
        --payload=payload

    if not is_success_status_code_ response.status_code:
      message := ""

      body_bytes := #[]
      while chunk := response.body.read: body_bytes += chunk

      exception := catch:
        decoded := json_encoding.decode body_bytes
        message = decoded.get "msg" or
            decoded.get "message" or
            decoded.get "error_description" or
            decoded.get "error" or
            body_bytes.to_string_non_throwing
      if exception:
        message = body_bytes.to_string_non_throwing
      throw "FAILED: $response.status_code - $message"

    if not parse_response_json:
      result_bytes := #[]
      while chunk := response.body.read: result_bytes += chunk
      return result_bytes.to_string_non_throwing

    // Still check whether there is a response.
    // When performing an RPC we can't know in advance whether the function
    // returns something or not.
    buffered_reader := BufferedReader response.body
    if not buffered_reader.can_ensure 1:
      return null

    result := json_encoding.decode_stream buffered_reader
    // TODO(florian): this shouldn't be necessary in the latest http package.
    response.body.read  // Make sure we drain the body.
    return result

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

/**
A client for the PostgREST API.

PostgREST uses 'GET', 'POST', 'PATCH', 'PUT', and 'DELETE' requests to
  perform CRUD operations on tables.

- 'GET' requests are used to retrieve rows from a table.
- 'POST' requests are used to insert rows into a table.
- 'PATCH' requests are used to update rows in a table.
- 'PUT' requests are used to replace a single row in a table.
- 'DELETE' requests are used to delete rows from a table.
*/
class PostgRest:
  /**
  For 'POST' requests (inserts), the response is empty, and only
    contains a 'Location' header with the primary key of the newly
    inserted row.
  This return preference must not be used for other requests.

  Note that this return preference leads to a permission error if the
    table is only write-only.
  */
  static RETURN_HEADER_ONLY_ ::= "header-only"
  /**
  The response is the full representation.

  This return preference is allowed for 'POST', 'PATCH', 'DELETE' and
    'PUT' requests.
  */
  static RETURN_REPRESENTATION_ ::= "representation"
  /**
  The response does not include the 'Location' header, as would be
    the case with 'RETURN_HEADER_ONLY'. This return preference must
    be used when writing into a table that is write-only.

  This return preference is allowed for 'POST', 'PATCH', 'DELETE' and
    'PUT' requests.
  */
  static RETURN_MINIMAL_ ::= "minimal"

  client_/Client

  constructor .client_:

  /**
  Returns a list of rows that match the filters.
  */
  select table/string --filters/List=[] -> List:
    // TODO(florian): the filters need to be URL encoded.
    query_filters := filters.join "&"
    return client_.request_
        --method=http.GET
        --path="/rest/v1/$table"
        --query=query_filters

  /**
  Inserts a new row to the table.

  If the row would violate a unique constraint, then the operation fails.

  If $return_inserted is true, then returns the inserted row.
  */
  insert table/string payload/Map --return_inserted/bool=true -> Map?:
    headers := http.Headers
    headers.add "Prefer" "return=$(return_inserted ? RETURN_REPRESENTATION_ : RETURN_MINIMAL_)"
    response := client_.request_
        --method=http.POST
        --headers=headers
        --path="/rest/v1/$table"
        --payload=payload
        --parse_response_json=return_inserted
    if return_inserted:
      return response.size == 0 ? null : response[0]
    return null

  /**
  Performs an 'update' operation on a table.
  */
  update table/string payload/Map --filters/List -> none:
    // TODO(florian): the filters need to be URL encoded.
    query_filters := filters.join "&"
    // We are not using the response. Use the minimal response.
    headers := http.Headers
    headers.add "Prefer" RETURN_MINIMAL_
    client_.request_
        --method="PATCH"
        --headers=headers
        --path="/rest/v1/$table"
        --payload=payload
        --parse_response_json=false
        --query=query_filters

  /**
  Performs an 'upsert' operation on a table.

  The word "upsert" is a combination of "update" and "insert".
  If adding a row would violate a unique constraint, then the row is
    updated instead.
  */
  upsert table/string payload/Map --ignore_duplicates/bool=false -> none:
    // TODO(florian): add support for '--on_conflict'.
    // In that case the conflict detection is on the column given by
    // on_column (which must be 'UNIQUE').
    // Verify this, and add the parameter.
    headers := http.Headers
    preference := ignore_duplicates
        ? "resolution=ignore-duplicates"
        : "resolution=merge-duplicates"
    headers.add "Prefer" preference
    // We are not using the response. Use the minimal response.
    headers.add "Prefer" RETURN_MINIMAL_
    client_.request_
        --method=http.POST
        --headers=headers
        --path="/rest/v1/$table"
        --payload=payload
        --parse_response_json=false

  /**
  Deletes all rows that match the filters.

  If no filters are given, then all rows are deleted.
  */
  delete table/string --filters/List -> none:
    // TODO(florian): the filters need to be URL encoded.
    query_filters := filters.join "&"
    // We are not using the response. Use the minimal response.
    headers := http.Headers
    headers.add "Prefer" RETURN_MINIMAL_
    client_.request_
        --method=http.DELETE
        --headers=headers
        --path="/rest/v1/$table"
        --parse_response_json=false
        --query=query_filters

  /**
  Performs a remote procedure call (RPC).
  */
  rpc name/string payload/Map -> any:
    return client_.request_
        --method=http.POST
        --path="/rest/v1/rpc/$name"
        --payload=payload

class Storage:
  client_/Client

  constructor .client_:

  // TODO(florian): add support for changing and deleting.
  // TODO(florian): add support for 'get_public_url'.
  //    should be as simple as "$url/storage/v1/object/public/$path"

  /**
  Uploads data to the storage.

  If $upsert is true, then the data is overwritten if it already exists.
  */
  upload --path/string --content/ByteArray --upsert/bool=true -> none:
    headers := http.Headers
    if upsert: headers.add "x-upsert" "true"
    headers.add "Content-Type" "application/octet-stream"
    client_.request_
        --method=http.POST
        --headers=headers
        --path="/storage/v1/object/$path"
        --payload=content
        --parse_response_json=false

  /**
  Downloads the data stored in $path from the storage.

  If $public is true, downloads the data through the public URL.
  */
  download --path/string --public/bool=false -> ByteArray:
    download --path=path --public=public: | reader/SizedReader |
      result := ByteArray reader.size
      offset := 0
      while chunk := reader.read:
        result.replace offset chunk
        offset += chunk.size
      return result
    unreachable

  /**
  Downloads the data stored in $path from the storage.

  Calls the given $block with a $SizedReader and the total size of the resource. If
    the download is not partial, then the total size is equal to the size of the
    $SizedReader.

  If $public is true, downloads the data through the public URL.
  */
  download --public/bool=false --path/string --offset/int=0 --size/int?=null [block] -> none:
    partial := false
    headers/http.Headers? := null
    if offset != 0 or size:
      partial = true
      end := size ? "$(offset + size - 1)" : ""
      headers = http.Headers
      headers.add "Range" "bytes=$offset-$end"
    full_path := public
        ? "storage/v1/object/public/$path"
        : "storage/v1/object/$path"
    response := client_.request_ --raw_response
        --method=http.GET
        --path=full_path
        --headers=headers
    // Check the status code. The correct result depends on whether
    // or not we're doing a partial fetch.
    status := response.status_code
    body := response.body as SizedReader
    okay := status == 200 or (partial and status == 206)
    if not okay:
      while data := body.read: null // DRAIN!
      throw "Not found ($status)"
    // We got a response we can use. If it is partial we
    // need to decode the response header to find the
    // total size.
    if partial and status != 200:
      // TODO(kasper): Try to avoid doing this for all parts.
      // We only really need to do it for the first.
      range := response.headers.single "Content-Range"
      divider := range.index_of "/"
      total_size := int.parse range[divider + 1..range.size]
      block.call body total_size
    else:
      block.call body body.size
    while data := body.read: null // DRAIN!

  /**
  Returns a list of all buckets.
  */
  list_buckets -> List:
    return client_.request_
        --method=http.GET
        --path="/storage/v1/bucket"
        --parse_response_json=true

  /**
  Returns a list of all objects at the given path.
  The path must not be empty.
  */
  list path/string -> List:
    if path == "": throw "INVALID_ARGUMENT"
    first_slash := path.index_of "/"
    bucket/string := ?
    prefix/string := ?
    if first_slash == -1:
      bucket = path
      prefix = ""
    else:
      bucket = path[0..first_slash]
      prefix = path[first_slash + 1..path.size]

    payload := {
      "prefix": prefix,
    }
    return client_.request_
        --method=http.POST
        --path="/storage/v1/object/list/$bucket"
        --parse_response_json=true
        --payload=payload

  /**
  Computes the public URL for the given $path.
  */
  public_url_for --path/string -> string:
    return "$client_.host_/object/public/$path"
