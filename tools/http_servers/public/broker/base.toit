// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import encoding.json
import http
import io
import log
import net
import net.tcp
import monitor

class BinaryResponse:
  bytes/ByteArray
  total-size/int

  constructor .bytes .total-size:

abstract class HttpServer:
  port/int? := null

  socket_/tcp.ServerSocket? := null

  /**
  List of listeners.
  Each lambda in this list is called twice for each command:
  1. Once befor the command is executed, with ("pre", <command>, data).
  2. After the command finished, with ("post", <command>, <result>), or ("error", <command>, <error>).

  Typically, listeners are only used in tests.
  */
  listeners/List := []

  constructor .port:

  close:
    if socket_:
      socket_.close
      socket_ = null

  abstract run-command command/int encoded/ByteArray user-id/string? -> any

  /** Handles the conventional interface-oriented API used by new CLIs. */
  run-request method/string path/string query/Map body/ByteArray headers/http.Headers user-id/string? -> any:
    throw "Conventional API not supported"

  /**
  Starts the server in a blocking way.

  Sets the given $port-latch with the value of the port on which the server is
    listening.
  */
  start port-latch/monitor.Latch?=null:
    network := net.open
    socket := network.tcp-listen (port or 0)
    port = socket.local-address.port
    if port-latch: port-latch.set port
    server := http.Server --max-tasks=64 --logger=(log.default.with-level log.INFO-LEVEL)
    print "Listening on port $socket.local-address.port"
    server.listen socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
      user-id := request.headers.single "X-User-Id"
      if not request.headers.single "X-Artemis-Header":
        throw "Missing X-Artemis-Header"

      bytes := request.body.read-all
      resource := request.query.resource
      if resource == "/":
        command := bytes[0]
        encoded := bytes[1..]
        listeners.do: it.call "pre" command encoded user-id
        reply_ command writer --legacy=true:
          run-command command encoded user-id
      else:
        listeners.do: it.call "pre" resource bytes user-id
        reply_ resource writer --legacy=false:
          run-request
              request.method
              resource
              request.query.parameters
              bytes
              request.headers
              user-id

  reply_ request-id/any writer/http.ResponseWriter --legacy/bool [block]:
    response-data := null
    exception := catch --trace:
      with-timeout --ms=3_000:
        response-data = block.call
    if exception:
      listeners.do: it.call "error" request-id exception
      encoded-response := legacy
          ? json.encode exception
          : json.encode {"message": "$exception"}
      writer.headers.set "Content-Length" "$encoded-response.size"
      writer.write-headers (legacy ? http.STATUS-IM-A-TEAPOT : http.STATUS-INTERNAL-SERVER-ERROR) --message="Error"
      writer.out.write encoded-response
    else:
      listeners.do: it.call "post" request-id response-data
      if response-data is BinaryResponse:
        binary := response-data as BinaryResponse
        status := http.STATUS-OK
        if binary.bytes.size != binary.total-size:
          writer.headers.add "Content-Range" "$binary.bytes.size/$binary.total-size"
          status = http.STATUS-PARTIAL-CONTENT
        writer.headers.set "Content-Length" "$binary.bytes.size"
        writer.write-headers status
        writer.out.write binary.bytes
      else:
        encoded-response := json.encode response-data
        writer.headers.set "Content-Length" "$encoded-response.size"
        writer.out.write encoded-response
