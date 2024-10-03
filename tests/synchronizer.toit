// Copyright (C) 2024 Toitware ApS. All rights reserved.

import io
import monitor
import net
import net.tcp

import ..tools.lan_ip.lan-ip

/**
A simple class that can be used to synchronize a test and a device.
*/
class Synchronizer:
  network_/net.Client? := ?
  server-socket_/tcp.ServerSocket? := ?
  client-socket_/tcp.Socket? := null
  client-socket-latch_/monitor.Latch? := monitor.Latch
  task_/Task? := null

  constructor:
    network_ = net.open
    server-socket_ = network_.tcp-listen 0
    task_ = task::
      try:
        client-socket_ = server-socket_.accept
        client-socket-latch_.set client-socket_
      finally:
        task_ = null

  close:
    if task_:
      task_.cancel
    if client-socket_:
      client-socket_.close
      client-socket_ = null
    if server-socket_:
      server-socket_.close
      server-socket_ = null
    if network_:
      network_.close
      network_ = null

  ip -> string:
    return get-lan-ip

  port -> int:
    return server-socket_.local-address.port

  signal message/io.Data="signal\n" -> none:
    if not client-socket_:
      client-socket-latch_.get
    client-socket_.out.write --flush message
