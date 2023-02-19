// Copyright (C) 2022 Toitware ApS.

import bytes
import log
import mqtt.packets as mqtt
import mqtt.broker as mqtt
import mqtt.transport as mqtt
import mqtt.tcp as mqtt
import monitor
import net
import net.tcp
import artemis.shared.server_config show ServerConfigMqtt
import writer show Writer

with_toit_mqtt_broker --logger/log.Logger [block]:
  server_transport := TestServerTransport
  broker := mqtt.Broker server_transport --logger=logger
  broker_task := task:: broker.start
  port := server_transport.port
  print "MQTT broker listening on port: $port"

  try:
    server_config := ServerConfigMqtt "toit-mqtt"
        --host="localhost"
        --port=port
    block.call server_config
  finally:
    broker_task.cancel
    server_transport.close

class TestServerTransport implements mqtt.ServerTransport:
  network_ /net.Interface? := ?
  server_socket_ /tcp.ServerSocket? := ?

  constructor:
    network_ = net.open
    server_socket_ = network_.tcp_listen 0

  port -> int:
    return server_socket_.local_address.port

  listen callback/Lambda -> none:
    while true:
      accepted := server_socket_.accept
      if not accepted: continue

      client_transport := mqtt.TcpTransport accepted
      callback.call client_transport

  close -> none:
    if server_socket_:
      server_socket_.close
      server_socket_ = null
    if network_:
      network_.close
      network_ = null
