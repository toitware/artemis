// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import net
import net.tcp
import encoding.ubjson
import monitor
import supabase.utils

STATUS_IM_A_TEAPOT ::= 418

class PartialResponse:
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
  */
  listeners/List := []

  constructor .port:

  close:
    if socket_:
      socket_.close
      socket_ = null

  abstract run_command command/string data/any user_id/string? -> any

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
      message := ubjson.decode (utils.read_all request.body)

      command := message["command"]
      should_respond_binary := message.get "binary" or false
      data := message["data"]
      user_id := message.get "user_id"

      listeners.do: it.call "pre" command data user_id
      reply_ command writer --binary=should_respond_binary:
        run_command command data user_id

  reply_ command/string writer/http.ResponseWriter --binary/bool [block]:
    response_data := null
    exception := catch --trace: response_data = block.call
    if exception:
      listeners.do: it.call "error" command exception
      encoded := ubjson.encode exception
      writer.headers.set "Content-Length" "$encoded.size"
      writer.write_headers STATUS_IM_A_TEAPOT --message="Error"
      writer.write encoded
    else:
      listeners.do: it.call "post" command response_data
      if response_data is PartialResponse:
        if not binary: throw "Partial responses must be binary"
        partial := response_data as PartialResponse
        writer.headers.add "Content-Range" "$partial.bytes.size/$partial.total_size"
        response_data = partial.bytes
      if binary:
        writer.headers.set "Content-Length" "$response_data.size"
        writer.write response_data
      else:
        encoded := ubjson.encode response_data
        writer.headers.set "Content-Length" "$encoded.size"
        writer.write encoded
