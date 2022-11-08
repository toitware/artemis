// Copyright (C) 2022 Toitware ApS.

import bytes
import log
import mqtt.packets as mqtt
import mqtt.broker as mqtt
import mqtt.transport as mqtt
import monitor

with_toit_mqtt_broker --logger/log.Logger [block]:
  server_transport := TestServerTransport
  broker := mqtt.Broker server_transport --logger=logger
  broker_task := task:: broker.start

  try:
    block.call {
      "create-transport": (:: TestClientTransport server_transport)
    }
  finally:
    broker_task.cancel

class TestClientTransport implements mqtt.Transport:
  server_ /TestServerTransport
  pipe_ /TestTransportPipe? := null

  constructor .server_:
    reconnect

  write bytes/ByteArray -> int:
    pipe_.client_write bytes
    return bytes.size

  read -> ByteArray?:
    return pipe_.client_read

  close -> none:
    pipe_.client_close

  supports_reconnect -> bool:
    return true

  reconnect -> none:
    pipe_ = server_.connect

  is_closed -> bool:
    return pipe_.client_is_closed

class TestBrokerTransport implements mqtt.BrokerTransport:
  pipe_ /TestTransportPipe

  constructor .pipe_:

  write bytes/ByteArray -> int:
    pipe_.broker_write bytes
    return bytes.size

  read -> ByteArray?:
    return pipe_.broker_read

  close -> none:
    pipe_.broker_close

class TestServerTransport implements mqtt.ServerTransport:
  channel_ /monitor.Channel := monitor.Channel 5

  is_closed /bool := false

  listen callback/Lambda -> none:
    while pipe := channel_.receive:
      callback.call (TestBrokerTransport pipe)

  connect -> TestTransportPipe:
    if is_closed:
      throw "Transport is closed"

    pipe := TestTransportPipe
    channel_.send pipe
    return pipe

  close -> none:
    is_closed = true
    channel_.send null

monitor TestTransportPipe:
  client_to_broker_data_ /Deque := Deque
  broker_to_client_data_ /Deque := Deque

  closed_from_client_ /bool := false
  closed_from_broker_ /bool := false

  client_write bytes/ByteArray -> none:
    if is_closed_: throw "CLOSED"
    client_to_broker_data_.add bytes

  client_read -> ByteArray?:
    await: broker_to_client_data_.size > 0 or is_closed_
    if closed_from_client_: throw "CLOSED"
    if broker_to_client_data_.is_empty: return null
    result := broker_to_client_data_.remove_first
    return result

  client_close:
    closed_from_client_ = true

  client_is_closed -> bool:
    return is_closed_

  broker_write bytes/ByteArray -> none:
    if is_closed_: throw "CLOSED"
    broker_to_client_data_.add bytes

  broker_read -> ByteArray?:
    await: client_to_broker_data_.size > 0 or is_closed_
    if closed_from_broker_: throw "CLOSED"
    if client_to_broker_data_.is_empty: return null
    return client_to_broker_data_.remove_first

  broker_close:
    closed_from_broker_ = true

  broker_is_closed -> bool:
    return is_closed_

  is_closed_ -> bool:
    return closed_from_client_ or closed_from_broker_
