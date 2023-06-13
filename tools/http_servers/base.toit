// Copyright (C) 2022 Toitware ApS. All rights reserved.

import encoding.json
import http
import net
import net.tcp
import monitor
import artemis.shared.utils

class BinaryResponse:
  bytes/ByteArray
  total_size/int

  constructor .bytes .total_size:

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

  abstract run_command command/int encoded/ByteArray user_id/string? -> any

  /**
  Starts the server in a blocking way.

  Sets the given $port_latch with the value of the port on which the server is
    listening.
  */
  start port_latch/monitor.Latch?=null:
    network := net.open
    socket := network.tcp_listen (port or 0)
    port = socket.local_address.port
    if port_latch: port_latch.set port
    server := http.Server --max_tasks=64
    print "Listening on port $socket.local_address.port"
    server.listen socket:: | request/http.Request writer/http.ResponseWriter |
      bytes := utils.read_all request.body
      command := bytes[0]
      encoded := bytes[1..]
      user_id := request.headers.single "X-User-Id"
      if not request.headers.single "X-Artemis-Header":
        throw "Missing X-Artemis-Header"

      listeners.do: it.call "pre" command encoded user_id
      reply_ command encoded user_id writer

  reply_ command/int encoded/ByteArray user_id/string? writer/http.ResponseWriter:
    response_data := null
    exception := catch --trace:
      response_data = run_command command encoded user_id
    if exception:
      listeners.do: it.call "error" command exception
      encoded_response := json.encode exception
      writer.headers.set "Content-Length" "$encoded_response.size"
      writer.write_headers http.STATUS_IM_A_TEAPOT --message="Error"
      writer.write encoded_response
    else:
      listeners.do: it.call "post" command response_data
      if response_data is BinaryResponse:
        binary := response_data as BinaryResponse
        status := http.STATUS_OK
        if binary.bytes.size != binary.total_size:
          writer.headers.add "Content-Range" "$binary.bytes.size/$binary.total_size"
          status = http.STATUS_PARTIAL_CONTENT
        writer.headers.set "Content-Length" "$binary.bytes.size"
        writer.write_headers status
        writer.write binary.bytes
      else:
        encoded_response := json.encode response_data
        writer.headers.set "Content-Length" "$encoded_response.size"
        writer.write encoded_response
