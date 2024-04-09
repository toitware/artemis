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
    server.listen socket:: | request/http.Request writer/http.ResponseWriter |
      bytes := request.body.read-all
      command := bytes[0]
      encoded := bytes[1..]
      user-id := request.headers.single "X-User-Id"
      if not request.headers.single "X-Artemis-Header":
        throw "Missing X-Artemis-Header"

      listeners.do: it.call "pre" command encoded user-id
      reply_ command encoded user-id writer

  reply_ command/int encoded/ByteArray user-id/string? writer/http.ResponseWriter:
    response-data := null
    exception := catch --trace:
      with-timeout --ms=3_000:
        response-data = run-command command encoded user-id
    if exception:
      listeners.do: it.call "error" command exception
      encoded-response := json.encode exception
      writer.headers.set "Content-Length" "$encoded-response.size"
      writer.write-headers http.STATUS-IM-A-TEAPOT --message="Error"
      writer.out.write encoded-response
    else:
      listeners.do: it.call "post" command response-data
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
