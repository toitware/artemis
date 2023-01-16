// Copyright (C) 2022 Toitware ApS. All rights reserved.

import http
import net
import net.tcp
import encoding.ubjson
import monitor

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
    server := http.Server
    print "Listening on port $socket.local_address.port"
    server.listen socket:: | request/http.Request writer/http.ResponseWriter |
      encoded_message := #[]
      while chunk := request.body.read:
        encoded_message += chunk
      message := ubjson.decode encoded_message

      command := message["command"]
      data := message["data"]
      user_id := message.get "user_id"

      listeners.do: it.call "pre" command data user_id
      reply_ command writer: run_command command data user_id

  reply_ command/string writer/http.ResponseWriter [block]:
    response_data := null
    exception := catch --trace: response_data = block.call
    if exception:
      listeners.do: it.call "error" command exception
      writer.write (ubjson.encode {
        "success": false,
        "error": "$exception",
      })
    else:
      listeners.do: it.call "post" command response_data
      writer.write (ubjson.encode {
        "success": true,
        "data": response_data
      })
