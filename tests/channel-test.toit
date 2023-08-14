// Copyright (C) 2022 Toitware ApS.

import system.services
import expect show *

import artemis.service.pkg-artemis-src-copy.artemis
import artemis.service.pkg-artemis-src-copy.api
import artemis.service.channels show ChannelResource ChannelServiceProvider

main:
  provider := TestServiceProvider
  provider.install
  spawn:: test
  // Uninstall after waiting for the first client to connect
  // and the last client to disconnect.
  provider.uninstall --wait

test:
  test-send "fisk"
  3.repeat: test-simple "fisk"
  test-neutering "hest"
  test-full "fisk"
  test-multi "fisk"
  test-multi "hest"

test-send topic/string:
  channel := artemis.Channel.open --topic=topic
  1999.repeat: channel.send #[1, 2, 3, 4, 5]
  channel.close

test-simple topic/string:
  channel := artemis.Channel.open --topic=topic --receive
  drain-channel channel

  position := channel.position
  try:
    list := List 200: (ByteArray 60 + (random 40): random 0x100)
    list.do: channel.send it
    list.size.repeat:
      expect-equals (position + it) channel.position
      expect-bytes-equal list[it] channel.receive
      // Test the < and > operator.
      expect position < channel.position
      expect channel.position > position
    expect-null channel.receive
    expect-throw "OUT_OF_RANGE: 209 > 200": channel.acknowledge 209
    position = channel.position
    remaining := list.size
    while remaining > 0:
      n := 1 + (random remaining)
      channel.acknowledge n
      expect-equals position channel.position
      remaining -= n
    expect-throw "OUT_OF_RANGE: 1 > 0": channel.acknowledge
    expect-equals position channel.position
  finally:
    channel.close

test-neutering topic/string:
  [1, 2, 5, 127, 128, 129, 512, 1024, 3000].do:
    test-neutering topic it

test-neutering topic/string size/int:
  test-neutering topic:
    ByteArray size: random 0x100
  test-neutering topic:
    bytes := ByteArray_.external_ size
    bytes.size.repeat: bytes[it] = random 0x100
    bytes

test-neutering topic/string [create]:
  channel := artemis.Channel.open --topic=topic --receive
  drain-channel channel

  element := create.call
  copy := element.copy
  channel.send element
  expect-bytes-equal copy element
  expect-bytes-equal copy channel.receive
  channel.acknowledge 1

  element = create.call
  if element.size > 1:
    element = element[1..]
    expect element is ByteArraySlice_
    copy = element.copy
    channel.send element
    expect-bytes-equal copy element
    expect-bytes-equal copy channel.receive
    channel.acknowledge 1

  channel.close

test-full topic/string:
  channel := artemis.Channel.open --topic=topic --receive
  drain-channel channel

  sent := 0
  while true:
    channel.send #[1] --if-full=: break
    sent++
  expect-equals 16328 sent

  full := false
  element := #[1]
  channel.send element --if-full=:
    expect-identical element it
    full = true
  expect full

  expect-throw "OUT_OF_BOUNDS": channel.send #[1]

  channel.close

test-multi topic/string:
  channel := artemis.Channel.open --topic=topic --receive
  expect-throw "ALREADY_IN_USE":
    artemis.Channel.open --topic=topic --receive
  drain-channel channel

  received := []
  try:
    5.repeat: | index |
      task::
        sender := artemis.Channel.open --topic=topic
        expect-throw "ALREADY_IN_USE":
          artemis.Channel.open --topic=topic --receive
        expect-throw "PERMISSION_DENIED":
          sender.receive
        expect-throw "OUT_OF_RANGE: 1 > 0":
          sender.acknowledge
        50.repeat:
          sender.send #[index, random 0x100]
          sleep --ms=2 + (random 7)
        sender.close
    (5 * 50).repeat:
      while channel.is-empty: sleep --ms=50
      received.add channel.receive.copy
      channel.acknowledge
    expect-throw "ALREADY_IN_USE":
      artemis.Channel.open --topic=topic --receive
  finally:
    channel.close

  5.repeat: | index |
    expect-equals 50 (received.filter: it[0] == index).size

drain-channel channel/artemis.Channel -> none:
  while not channel.is-empty:
    channel.receive
    n := channel.buffered
    n.repeat: channel.receive
    channel.acknowledge n + 1

// --------------------------------------------------------------------------

class TestServiceProvider extends ChannelServiceProvider
    implements services.ServiceHandler:
  constructor:
    super "toit.io/test-artemis" --major=1 --minor=0
    provides api.ArtemisService.SELECTOR --handler=this
